local Config = require("sidekick.config")
local Session = require("sidekick.cli.session")
local Terminal = require("sidekick.cli.terminal")
local Util = require("sidekick.util")

local M = {}

---@class sidekick.cli.State
---@field tool sidekick.cli.Tool
---@field attached? boolean
---@field external? boolean
---@field installed? boolean
---@field session? sidekick.cli.Session
---@field started? boolean
---@field terminal? sidekick.cli.Terminal
---@field name? string

---@class sidekick.cli.Filter
---@field attached? boolean
---@field cwd? boolean
---@field external? boolean
---@field installed? boolean
---@field name? string
---@field owned? boolean tools without a session, or sessions attached in this nvim instance
---@field session? string
---@field started? boolean
---@field terminal? boolean

---@class sidekick.cli.With
---@field filter? sidekick.cli.Filter
---@field show? boolean
---@field focus? boolean
---@field attach? boolean
---@field all? boolean

---@param t sidekick.cli.State
---@param filter? sidekick.cli.Filter
function M.is(t, filter)
  filter = filter or {}
  return (filter.attached == nil or filter.attached == t.attached)
    and (filter.cwd == nil or (t.session and t.session.cwd == Session.cwd()))
    and (filter.external == nil or filter.external == t.external)
    and (filter.installed == nil or filter.installed == t.installed)
    and (filter.name == nil or filter.name == t.tool.name)
    and (filter.owned == nil or filter.owned == (not t.session or Session.is_owned(t.session)))
    and (filter.session == nil or (t.session and t.session.id == filter.session))
    and (filter.started == nil or filter.started == t.started)
    and (filter.terminal == nil or filter.terminal == (t.terminal ~= nil))
end

---@param session sidekick.cli.Session
function M.get_state(session)
  ---@type sidekick.cli.State
  return setmetatable({
    session = session,
    installed = true, -- it's running, so it must be installed
  }, {
    __index = function(_, k)
      if k == "tool" or k == "started" or k == "external" or k == "name" then
        return session[k]
      elseif k == "attached" then
        return session:is_attached()
      elseif k == "terminal" then
        return session.backend == "terminal" and Terminal.get(session.id) or nil
      end
    end,
  })
end

---@param filter? sidekick.cli.Filter
---@return sidekick.cli.State[]
function M.get(filter)
  filter = filter or {}
  local all = {} ---@type sidekick.cli.State[]
  local sessions = filter.attached and Session.attached() or Session.sessions()

  -- Pass 1: decide which sessions are suppressed by a higher-priority
  -- overlapping session, and let the survivor inherit the suppressed
  -- session's name (only the raw, lower-priority entry ever carries one).
  local skip = {} ---@type table<sidekick.cli.Session, boolean>
  for _, s in pairs(sessions) do
    if not s:is_attached() then
      for _, s2 in pairs(sessions) do
        if s2 ~= s and Util.overlaps(s2.pids or {}, s.pids or {}) and s2.priority > s.priority then
          skip[s] = true
          if s.name and s.name ~= "" then
            s2.name = s.name
          end
          break
        end
      end
    end
  end

  -- Pass 2: build the state list from what survived.
  for _, s in pairs(sessions) do
    if not skip[s] then
      all[#all + 1] = M.get_state(s)
    end
  end

  if not filter.attached then
    for name, tool in pairs(Config.tools()) do
      all[#all + 1] = {
        tool = tool,
        installed = vim.fn.executable(tool.cmd[1]) == 1,
      }
    end
  end

  local cwd = Session.cwd()

  ---@type sidekick.cli.State[]
  ---@param t sidekick.cli.State
  local ret = vim.tbl_filter(function(t)
    return M.is(t, filter)
  end, all)
  table.sort(ret, function(a, b)
    if a.installed ~= b.installed then
      return a.installed
    end
    -- sessions in cwd, or tools without a session
    local a_cwd = (not a.session or a.session.cwd == cwd or false)
    local b_cwd = (not b.session or b.session.cwd == cwd or false)
    if a_cwd ~= b_cwd then
      return a_cwd
    end
    if a.started ~= b.started then
      return a.started
    end
    if (a.terminal ~= nil) ~= (b.terminal ~= nil) then
      return a.terminal ~= nil
    end
    if a.external ~= b.external then
      return not a.external
    end
    return a.tool.name < b.tool.name
  end)
  return ret
end

--- Narrows a list of attached states down to the ones currently visible
--- in an open terminal window.
---@param states sidekick.cli.State[]
---@return sidekick.cli.State[]
function M.filter_visible(states)
  return vim.tbl_filter(function(s)
    return s.terminal ~= nil and s.terminal:is_open()
  end, states)
end

--- Executes a callback with one or more attached sessions.
---@param cb fun(state: sidekick.cli.State, attached?: boolean):any?
---@param opts? sidekick.cli.With
function M.with(cb, opts)
  opts = opts or {}
  cb = vim.schedule_wrap(cb)

  ---@param state sidekick.cli.State
  local use = vim.schedule_wrap(function(state)
    if not state then
      return
    end
    local ret, attached = M.attach(state, { show = opts.show, focus = opts.focus })
    cb(ret, attached)
  end)

  local filter_attached = Util.merge(opts.filter, { attached = true })
  local attached = M.get(filter_attached)

  if #attached == 0 and opts.attach then
    -- Only (re)attach sessions previously attached in this nvim instance.
    -- Others (started elsewhere, or before a restart) are left to `select()`.
    local owned = Util.merge(opts.filter, { owned = true })
    local started = M.get(Util.merge(owned, { started = true }))
    if #started == 1 then
      use(started[1])
    else
      require("sidekick.cli.ui.select").select({
        auto = true,
        filter = owned,
        cb = use,
      })
    end
    return
  end

  if #attached > 1 and not opts.all then
    local visible = M.filter_visible(attached)
    if #visible == 1 then
      attached = visible
    else
      require("sidekick.cli.ui.select").select({
        auto = true,
        filter = filter_attached,
        cb = use,
      })
      return
    end
  end

  vim.tbl_map(use, attached)
end

---@param state sidekick.cli.State
---@param opts? {show?:boolean, focus?:boolean}
---@return sidekick.cli.State state, boolean attached whether we just attached
function M.attach(state, opts)
  opts = opts or {}
  local attached = state.session == nil or not state.attached
  local tool = state.tool

  -- if the session is already attached, the below is a no-op
  local session = state.session
  if not session then
    local cwd = Session.cwd()
    for _, s in pairs(Session.attached()) do
      if s.tool.name == tool.name and s.cwd == cwd then
        session = s
        break
      end
    end
    session = session or Session.new({ tool = tool.name })
    -- Picking a bare tool means starting it. Don't let `tmux new -A` silently
    -- attach to a session (e.g. from another nvim instance) that took the name.
    if session.backend == "tmux" and not session.started and not session.external then
      for _, s in ipairs(Session.sessions()) do
        if not s.external and s.mux_session == session.mux_session then
          session = Session.new({ tool = tool.name, iid = ("%x"):format(vim.uv.hrtime()) })
          break
        end
      end
    end
  end
  session = Session.attach(session)

  state = M.get_state(session) -- update state
  local terminal = state.terminal
  if terminal then
    if opts.show then
      terminal:show()
      if opts.focus ~= false and terminal:is_running() then
        terminal:focus()
      end
    end
  elseif attached then
    Util.info("Attached to `" .. state.tool.name .. "`")
  end
  return state, attached
end

---@param state sidekick.cli.State
function M.detach(state)
  if state.session and state.attached then
    if state.terminal then
      state.terminal:close()
    else
      Session.detach(state.session)
      Util.info("Detached from `" .. state.tool.name .. "`")
    end
  end
  return state
end

return M
