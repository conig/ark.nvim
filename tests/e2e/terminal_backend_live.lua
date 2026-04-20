local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local stop_watchdog = ark_test.start_watchdog(60000, "terminal_backend_live")

local repo_root = vim.fn.getcwd()
local run_tmpdir = ark_test.run_tmpdir()
local status_dir = vim.fs.normalize(run_tmpdir .. "/terminal-status")
vim.fn.mkdir(status_dir, "p")

local source_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_bufnr)
vim.api.nvim_buf_set_name(source_bufnr, vim.fs.normalize(run_tmpdir .. "/terminal_backend_live.R"))
vim.bo[source_bufnr].filetype = "r"
vim.api.nvim_buf_set_lines(source_bufnr, 0, -1, false, {
  "mean",
})

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  configure_slime = true,
  session = {
    backend = "terminal",
    kind = "ark",
  },
  terminal = {
    launcher = vim.fs.normalize(repo_root .. "/scripts/ark-r-launcher.sh"),
    split_direction = "horizontal",
    split_position = "botright",
    split_size = 8,
    session_kind = "ark",
    startup_status_dir = status_dir,
    session_pkg_path = vim.fs.normalize(repo_root .. "/packages/arkbridge"),
    session_lib_path = vim.fn.stdpath("data") .. "/ark/r-lib",
    bridge_wait_ms = 10000,
    session_timeout_ms = 1000,
  },
})

local pane_id, pane_err = ark.start_pane()
if not pane_id then
  stop_watchdog()
  ark_test.fail("failed to start terminal backend pane: " .. tostring(pane_err))
end

ark_test.wait_for("terminal bridge ready", 30000, function()
  local status = ark.status()
  return type(status) == "table" and status.backend == "terminal" and status.bridge_ready == true
end)

ark_test.wait_for("terminal repl ready", 30000, function()
  local status = ark.status()
  return type(status) == "table" and status.repl_ready == true
end)

local status = ark.status()
if status.backend ~= "terminal" then
  stop_watchdog()
  ark_test.fail("expected terminal backend status, got " .. vim.inspect(status))
end

if type(status.session_id) ~= "string" or status.session_id == "" then
  stop_watchdog()
  ark_test.fail("expected terminal session id, got " .. vim.inspect(status))
end

if type(status.startup_status_path) ~= "string" or status.startup_status_path == "" then
  stop_watchdog()
  ark_test.fail("expected terminal startup status path, got " .. vim.inspect(status))
end

if vim.fn.filereadable(status.startup_status_path) ~= 1 then
  stop_watchdog()
  ark_test.fail("expected terminal status file to exist: " .. tostring(status.startup_status_path))
end

if vim.g.slime_target ~= "neovim" then
  stop_watchdog()
  ark_test.fail("expected vim-slime neovim target, got " .. vim.inspect(vim.g.slime_target))
end

if type(vim.g.slimetree_terminal_config) ~= "table" then
  stop_watchdog()
  ark_test.fail("expected managed slimetree terminal config, got " .. vim.inspect(vim.g.slimetree_terminal_config))
end

if vim.g.slimetree_terminal_config.bufnr ~= status.terminal_bufnr then
  stop_watchdog()
  ark_test.fail("unexpected managed terminal bufnr: " .. vim.inspect(vim.g.slimetree_terminal_config))
end

if type(vim.b[source_bufnr].slime_config) ~= "table"
  or vim.b[source_bufnr].slime_config.jobid ~= status.terminal_jobid
then
  stop_watchdog()
  ark_test.fail("expected source buffer slime config to target managed terminal: " .. vim.inspect(vim.b[source_bufnr].slime_config))
end

local send_ok, send_err = require("ark.terminal").send_text([[cat("ark-terminal-send-ok\n"); flush.console()]])
if not send_ok then
  stop_watchdog()
  ark_test.fail("failed to send text to managed terminal: " .. tostring(send_err))
end

ark_test.wait_for("terminal send output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(status.terminal_bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("ark%-terminal%-send%-ok") ~= nil
end)

ark.stop_pane()
stop_watchdog()
