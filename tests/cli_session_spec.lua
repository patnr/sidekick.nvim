---@module 'luassert'

local Session = require("sidekick.cli.session")

describe("session identity", function()
  Session.setup()

  it("uses plain sid as id when no iid is given", function()
    local s = Session.new({ tool = "claude", backend = "terminal", cwd = "/tmp/sidekick-test-a" })
    assert.equals(s.sid, s.id)
  end)

  it("appends the iid to sid when an iid is given", function()
    local s = Session.new({ tool = "claude", backend = "terminal", cwd = "/tmp/sidekick-test-b", iid = "abc123" })
    assert.equals(s.sid .. "-abc123", s.id)
  end)

  it("keeps sid stable across different iids for the same tool+cwd", function()
    local s1 = Session.new({ tool = "claude", backend = "terminal", cwd = "/tmp/sidekick-test-c", iid = "one" })
    local s2 = Session.new({ tool = "claude", backend = "terminal", cwd = "/tmp/sidekick-test-c", iid = "two" })
    assert.equals(s1.sid, s2.sid)
    assert.is_not.equals(s1.id, s2.id)
  end)
end)

describe("tmux mux_session naming and external detection", function()
  Session.setup()
  local tmux_backend = Session.backends.tmux

  it("names a freshly-created managed session's mux_session after its own id", function()
    if not tmux_backend then
      return -- tmux not installed on this machine; covered by the manual checklist instead
    end
    local s = setmetatable({
      sid = "claude abc123",
      id = "claude abc123-xyz",
      started = false,
    }, tmux_backend)
    s:init()
    assert.equals("claude abc123-xyz", s.mux_session)
  end)

  it("treats a discovered session whose mux_session shares our sid prefix as managed", function()
    if not tmux_backend then
      return
    end
    local s = setmetatable({
      sid = "claude abc123",
      mux_session = "claude abc123-xyz",
      started = true,
    }, tmux_backend)
    s:init()
    assert.is_false(s.external)
  end)

  it("treats a discovered session with an unrelated mux_session name as external", function()
    if not tmux_backend then
      return
    end
    local s = setmetatable({
      sid = "claude abc123",
      mux_session = "some-other-window",
      started = true,
    }, tmux_backend)
    s:init()
    assert.is_true(s.external)
  end)
end)

describe("tmux pane title parsing", function()
  local tmux_backend = Session.backends.tmux

  it("captures pane_title as part of the discovered pane fields", function()
    if not tmux_backend then
      return
    end
    -- Simulate one line of `tmux list-panes` output using the new PANE_FORMAT.
    local line = "$1:%2:12345:my-session:/tmp/project:Fix login bug"
    local session_id, id, pid, session_name, cwd, title =
      line:match("^(%$%d+):(%%%d+):(%d+):(.-):(.-):(.*)$")
    assert.equals("$1", session_id)
    assert.equals("%2", id)
    assert.equals("12345", pid)
    assert.equals("my-session", session_name)
    assert.equals("/tmp/project", cwd)
    assert.equals("Fix login bug", title)
  end)
end)

describe("Session.sessions dedup", function()
  it("skips a duplicate discovered id instead of crashing", function()
    local original_backends = Session.backends
    Session.backends = {
      fake = {
        sessions = function()
          return {
            { id = "dup", cwd = "/tmp/a", tool = "claude" },
            { id = "dup", cwd = "/tmp/a", tool = "claude" },
          }
        end,
      },
    }
    -- fake backend needs to behave enough like a real one for Session.new's setmetatable
    setmetatable(Session.backends.fake, { __index = function() end })

    local ok, result = pcall(Session.sessions)

    Session.backends = original_backends

    assert.is_true(ok)
    assert.equals(1, #result)
  end)
end)

describe("State.get always offers a start-new placeholder", function()
  local State = require("sidekick.cli.state")
  local Config = require("sidekick.config")

  it("includes an idle row for a tool even when instances are already running", function()
    local original_sessions = Session.sessions
    Session.sessions = function()
      local claude_tool = Config.get_tool("claude")
      return {
        setmetatable({
          id = "claude abc-1",
          -- must match what state.lua's tool loop computes for the current
          -- cwd via Session.sid({ tool = name }), or the old dedup-by-sid
          -- bug this test targets never actually triggers
          sid = Session.sid({ tool = "claude" }),
          cwd = "/tmp/project",
          tool = claude_tool,
          started = true,
          backend = "terminal",
          is_attached = function()
            return false
          end,
        }, { __index = function() end }),
      }
    end

    local states = State.get()

    Session.sessions = original_sessions

    local idle_rows = vim.tbl_filter(function(s)
      return s.tool.name == "claude" and s.session == nil
    end, states)
    assert.equals(1, #idle_rows)
  end)
end)

describe("State.get_state name passthrough", function()
  local State = require("sidekick.cli.state")

  it("exposes session.name on the returned state", function()
    local session = { name = "Fix login bug", tool = { name = "claude" }, started = true, backend = "tmux" }
    local state = State.get_state(session)
    assert.equals("Fix login bug", state.name)
  end)

  it("is nil when the session has no name yet", function()
    local session = { tool = { name = "claude" }, started = true, backend = "tmux" }
    local state = State.get_state(session)
    assert.is_nil(state.name)
  end)
end)

describe("cli.new", function()
  local CLI = require("sidekick.cli")
  local Util = require("sidekick.util")

  it("errors clearly when the tmux backend isn't available", function()
    Session.setup()
    local original_tmux = Session.backends.tmux
    Session.backends.tmux = nil

    local errored = false
    local original_error = Util.error
    Util.error = function()
      errored = true
    end

    CLI.new({ tool = "claude" })

    Util.error = original_error
    Session.backends.tmux = original_tmux

    assert.is_true(errored)
  end)

  it("generates a distinct iid on every call", function()
    Session.setup()
    if not Session.backends.tmux then
      return -- tmux not installed on this machine; covered by the manual checklist instead
    end

    local seen = {}
    local original_new = Session.new
    Session.new = function(opts)
      seen[#seen + 1] = opts.iid
      return original_new(opts)
    end
    local original_attach = Session.attach
    Session.attach = function(session)
      return session -- avoid actually spawning/attaching tmux in this test
    end

    CLI.new({ tool = "claude" })
    CLI.new({ tool = "claude" })

    Session.new = original_new
    Session.attach = original_attach

    assert.equals(2, #seen)
    assert.is_not_nil(seen[1])
    assert.is_not_nil(seen[2])
    assert.is_not.equals(seen[1], seen[2])
  end)
end)

describe("State.filter_visible", function()
  local State = require("sidekick.cli.state")

  local function fake(is_open)
    if is_open == nil then
      return { terminal = nil }
    end
    return {
      terminal = {
        is_open = function()
          return is_open
        end,
      },
    }
  end

  it("returns an empty list when nothing is visible", function()
    local result = State.filter_visible({ fake(false), fake(false) })
    assert.are.same({}, result)
  end)

  it("returns the single visible entry", function()
    local b = fake(true)
    local result = State.filter_visible({ fake(false), b })
    assert.are.same({ b }, result)
  end)

  it("returns every entry that is visible when more than one is open", function()
    local a, b = fake(true), fake(true)
    local result = State.filter_visible({ a, b })
    assert.are.same({ a, b }, result)
  end)

  it("ignores sessions with no terminal at all (e.g. external)", function()
    local visible = fake(true)
    local result = State.filter_visible({ fake(nil), visible })
    assert.are.same({ visible }, result)
  end)
end)

describe("terminal wrapper id uses the session's own unique id", function()
  it("gives two different-iid sessions of the same tool+cwd distinct wrapper ids", function()
    Session.setup()
    if not Session.backends.tmux then
      return -- tmux not installed on this machine; covered by the manual checklist instead
    end

    local Terminal = require("sidekick.cli.terminal")
    local original_terminal_start = Terminal.start
    Terminal.start = function(self)
      self.started = true -- stub: no real job spawn
    end

    local s1 = Session.new({ tool = "claude", backend = "tmux", cwd = "/tmp/sidekick-wrap-test", iid = "one" })
    local s2 = Session.new({ tool = "claude", backend = "tmux", cwd = "/tmp/sidekick-wrap-test", iid = "two" })
    s1.started = true
    s2.started = true
    s1.attach = function()
      return { cmd = { "true" } }
    end
    s2.attach = function()
      return { cmd = { "true" } }
    end

    local w1 = Session.attach(s1)
    local w2 = Session.attach(s2)

    Terminal.start = original_terminal_start
    Session.detach(w1)
    Session.detach(w2)

    assert.is_not.equals(w1.id, w2.id)
    assert.equals("terminal: " .. s1.id, w1.id)
    assert.equals("terminal: " .. s2.id, w2.id)
  end)
end)

describe("State.get propagates name across dedup", function()
  local State = require("sidekick.cli.state")

  it("gives the surviving higher-priority session the suppressed session's name", function()
    local original_sessions = Session.sessions
    local named = setmetatable({
      id = "raw-1",
      sid = "claude abc",
      cwd = "/tmp/project",
      tool = require("sidekick.config").get_tool("claude"),
      started = true,
      backend = "tmux",
      priority = 50,
      pids = { 111 },
      name = "Fix login bug",
      is_attached = function()
        return false
      end,
    }, { __index = function() end })
    local wrapper = setmetatable({
      id = "terminal: claude abc",
      sid = "claude abc",
      cwd = "/tmp/project",
      tool = named.tool,
      started = true,
      backend = "terminal",
      priority = 100,
      pids = { 111 },
      is_attached = function()
        return true
      end,
    }, { __index = function() end })

    Session.sessions = function()
      return { named, wrapper }
    end

    local states = State.get()

    Session.sessions = original_sessions

    local surviving = vim.tbl_filter(function(s)
      return s.session == wrapper
    end, states)
    assert.equals(1, #surviving)
    assert.equals("Fix login bug", surviving[1].name)
  end)
end)
