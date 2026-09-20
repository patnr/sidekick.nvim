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
