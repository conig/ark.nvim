local config = require("ark.config")
local terminal = require("ark.terminal")
local tmux = require("ark.tmux")

local defaults = config.defaults()

local tmux_cmd = tmux.pane_command({
  startup_status_dir = "/tmp/ark-status",
  session_pkg_path = "/tmp/arkbridge",
  session_lib_path = defaults.tmux.session_lib_path,
  launcher = "/tmp/ark-r-launcher.sh",
})

if tmux_cmd:find("clear &&", 1, true) ~= nil then
  error("expected tmux pane command to skip clear, got " .. tmux_cmd, 0)
end

local terminal_cmd = terminal.pane_command({
  startup_status_dir = "/tmp/ark-status",
  launcher = "/tmp/ark-r-launcher.sh",
  shell = defaults.terminal.shell,
})

if terminal_cmd:find("clear &&", 1, true) ~= nil then
  error("expected terminal pane command to skip clear, got " .. terminal_cmd, 0)
end
