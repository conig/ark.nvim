vim.opt.rtp:prepend(vim.fn.getcwd())

_G.__ark_nvim_state = {
  managed = true,
  pane_id = "%42",
  session = nil,
}

package.loaded["ark.tmux"] = nil

local original_system = vim.fn.system
local commands = {}

vim.fn.system = function(command)
  commands[#commands + 1] = vim.deepcopy(command)

  if type(command) ~= "table" then
    error("expected tmux invocation to use argv form, got " .. type(command), 0)
  end

  if vim.deep_equal(command, { "tmux", "display-message", "-p", "-t", "%42", "#{pane_id}" }) then
    return "%42\n"
  end

  if vim.deep_equal(command, { "tmux", "display-message", "-p", "-t", "%42", "#{socket_path}\n#{session_name}" }) then
    return "/tmp/ark.sock\nproject-session\n"
  end

  error("unexpected tmux command: " .. vim.inspect(command), 0)
end

local ok, err = pcall(function()
  local tmux = require("ark.tmux")
  local session = tmux.session()

  if not session then
    error("expected tmux.session() to resolve session metadata", 0)
  end

  if session.tmux_socket ~= "/tmp/ark.sock" then
    error("unexpected socket path: " .. vim.inspect(session), 0)
  end

  if session.tmux_session ~= "project-session" then
    error("unexpected session name: " .. vim.inspect(session), 0)
  end

  if session.tmux_pane ~= "%42" then
    error("unexpected pane id: " .. vim.inspect(session), 0)
  end

  for _, command in ipairs(commands) do
    if type(command) == "table" and vim.deep_equal(command, { "tmux", "list-panes", "-a", "-F", "#{pane_id}" }) then
      error("tmux.session() fell back to a global list-panes scan", 0)
    end
  end

  vim.print({
    commands = commands,
    session = session,
  })
end)

vim.fn.system = original_system

if not ok then
  error(err, 0)
end
