vim.opt.rtp:prepend(vim.fn.getcwd())

local console_frontend = require("ark.console_frontend")
local terminal = require("ark.terminal")
local tmux = require("ark.tmux")

local config = {
  launcher = "/tmp/ark-r-launcher.sh",
  console_frontend = "ark-terminal",
  startup_status_dir = "/tmp/ark status",
  session_pkg_path = "/tmp/arkbridge",
  session_lib_path = "/tmp/ark lib",
  lsp_bin = "/tmp/ark-lsp",
  ark_terminal = {
    bin = "/tmp/ark-terminal",
    trace_log = "/tmp/ark terminal.jsonl",
    print_status_json = true,
  },
}

local argv, argv_err = console_frontend.argv(config, "terminal", "session-1")
if not argv then
  error(argv_err, 0)
end

local expected = {
  "/tmp/ark-terminal",
  "--backend",
  "terminal",
  "--raw",
  "--status-dir",
  "/tmp/ark status",
  "--session-id",
  "session-1",
  "--ark-lsp",
  "/tmp/ark-lsp",
  "--trace-log",
  "/tmp/ark terminal.jsonl",
  "--print-status-json",
  "--",
  "/tmp/ark-r-launcher.sh",
}

if vim.inspect(argv) ~= vim.inspect(expected) then
  error("unexpected ark-terminal argv: " .. vim.inspect(argv), 0)
end

local enhanced_config = vim.deepcopy(config)
enhanced_config.ark_terminal.raw = false
local enhanced_argv, enhanced_argv_err = console_frontend.argv(enhanced_config, "terminal", "session-1")
if not enhanced_argv then
  error(enhanced_argv_err, 0)
end
for _, value in ipairs(enhanced_argv) do
  if value == "--raw" then
    error("enhanced ark-terminal argv should not include --raw: " .. vim.inspect(enhanced_argv), 0)
  end
end

local raw_argv, raw_err = console_frontend.argv({
  launcher = "/tmp/ark-r-launcher.sh",
  console_frontend = "raw",
}, "terminal", "session-1")
if not raw_argv then
  error(raw_err, 0)
end
if vim.inspect(raw_argv) ~= vim.inspect({ "/tmp/ark-r-launcher.sh" }) then
  error("unexpected raw argv: " .. vim.inspect(raw_argv), 0)
end

local terminal_cmd = terminal.pane_command(config)
if terminal_cmd:find("ARK_SESSION_ID='ark%-terminal%-session'", 1, false) == nil then
  error("terminal pane command did not export fallback session id: " .. terminal_cmd, 0)
end
if terminal_cmd:find("exec '/tmp/ark%-terminal'", 1, false) == nil then
  error("terminal pane command did not exec ark-terminal: " .. terminal_cmd, 0)
end
if terminal_cmd:find("'--' '/tmp/ark%-r%-launcher.sh'", 1, false) == nil then
  error("terminal pane command did not pass launcher after --: " .. terminal_cmd, 0)
end

local tmux_cmd = tmux.pane_command(config)
if tmux_cmd:find("ARK_NVIM_SESSION_PKG_PATH=", 1, true) == nil then
  error("tmux pane command lost launcher environment exports: " .. tmux_cmd, 0)
end
if tmux_cmd:find("exec '/tmp/ark%-terminal'", 1, false) == nil then
  error("tmux pane command did not exec ark-terminal: " .. tmux_cmd, 0)
end
if tmux_cmd:find("'--backend' 'tmux'", 1, true) == nil then
  error("tmux pane command did not pass tmux backend: " .. tmux_cmd, 0)
end

package.loaded["ark"] = nil
local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  session = {
    backend = "terminal",
    console_frontend = "ark-terminal",
  },
  terminal = {
    launcher = "/tmp/ark-r-launcher.sh",
    startup_status_dir = "/tmp/ark status",
    session_pkg_path = "/tmp/arkbridge",
    session_lib_path = "/tmp/ark lib",
    ark_terminal = {
      bin = "/tmp/ark-terminal",
    },
  },
})

local setup_cmd = ark.pane_command()
if setup_cmd:find("exec '/tmp/ark%-terminal'", 1, false) == nil then
  error("session.console_frontend did not propagate to terminal pane command: " .. setup_cmd, 0)
end
