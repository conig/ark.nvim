vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_history_persistence")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end


local console = require("ark.console")
local function input()
  local status = console.status(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false), "\n")
end
local function draft(text)
  vim.api.nvim_buf_set_lines(bufnr, console.status(bufnr).input_start, -1, false, { text })
end
draft("persist_me()")
assert(console.submit(bufnr))
ark_test.wait_for("submitted output", 4000, function()
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find("console saw: persist_me()", 1, true) ~= nil
end)
vim.api.nvim_buf_delete(bufnr, { force = true })
bufnr = assert(ark.console())
assert(console.status(bufnr).history[1] == "persist_me()")
draft("unsent_draft()")
assert(console.history_prev(bufnr))
assert(input() == "persist_me()")
assert(console.history_next(bufnr))
assert(input() == "unsent_draft()")
assert(#console.status(bufnr).history == 1, "recall must not execute")
stop_watchdog()
