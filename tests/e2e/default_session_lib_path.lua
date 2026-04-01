local config = require("ark.config")
local tmux = require("ark.tmux")

local defaults = config.defaults()
if defaults.tmux.session_lib_path ~= nil then
  error("expected default session_lib_path to be nil, got " .. vim.inspect(defaults.tmux.session_lib_path), 0)
end

local default_cmd = tmux.pane_command({
  startup_status_dir = "/tmp/ark-status",
  session_pkg_path = "/tmp/arkbridge",
  launcher = "/tmp/ark-r-launcher.sh",
})

if default_cmd:find("ARK_NVIM_SESSION_LIB=", 1, true) ~= nil then
  error("default pane command unexpectedly exported ARK_NVIM_SESSION_LIB: " .. default_cmd, 0)
end

local override_cmd = tmux.pane_command({
  startup_status_dir = "/tmp/ark-status",
  session_pkg_path = "/tmp/arkbridge",
  session_lib_path = "/tmp/ark-lib",
  launcher = "/tmp/ark-r-launcher.sh",
})

if override_cmd:find("ARK_NVIM_SESSION_LIB=", 1, true) == nil then
  error("override pane command did not export ARK_NVIM_SESSION_LIB: " .. override_cmd, 0)
end
