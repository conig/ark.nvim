local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local stop_watchdog = ark_test.start_watchdog(60000, "ark_terminal_frontend_live")

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  stop_watchdog()
  ark_test.fail("ark-terminal binary is not built or executable: " .. ark_terminal_bin)
end

local run_tmpdir = ark_test.run_tmpdir()
local status_dir = vim.fs.normalize(run_tmpdir .. "/ark-terminal-status")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal.jsonl")
vim.fn.mkdir(status_dir, "p")

local source_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_bufnr)
vim.api.nvim_buf_set_name(source_bufnr, vim.fs.normalize(run_tmpdir .. "/ark_terminal_frontend_live.R"))
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
    console_frontend = "ark-terminal",
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
    ark_terminal = {
      bin = ark_terminal_bin,
      trace_log = trace_log,
    },
  },
})

local pane_id, pane_err = ark.start_pane()
if not pane_id then
  stop_watchdog()
  ark_test.fail("failed to start ark-terminal frontend pane: " .. tostring(pane_err))
end

ark_test.wait_for("ark-terminal bridge ready", 30000, function()
  local status = ark.status()
  return type(status) == "table" and status.backend == "terminal" and status.bridge_ready == true
end)

ark_test.wait_for("ark-terminal repl ready", 30000, function()
  local status = ark.status()
  return type(status) == "table" and status.repl_ready == true
end)

local status = ark.status()
if type(status.session_id) ~= "string" or status.session_id == "" then
  stop_watchdog()
  ark_test.fail("expected ark-terminal session id, got " .. vim.inspect(status))
end

local send_ok, send_err = require("ark.terminal").send_text([[cat("ark-terminal-frontend-send-ok\n"); flush.console()]])
if not send_ok then
  stop_watchdog()
  ark_test.fail("failed to send text through ark-terminal frontend: " .. tostring(send_err))
end

ark_test.wait_for("ark-terminal send output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(status.terminal_bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("ark%-terminal%-frontend%-send%-ok") ~= nil
end)

ark_test.wait_for("ark-terminal trace log", 5000, function()
  return vim.fn.filereadable(trace_log) == 1
end)

ark.stop_pane()
stop_watchdog()
