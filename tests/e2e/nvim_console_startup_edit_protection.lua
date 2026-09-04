vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_startup_edit_protection")

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

-- Simulate an unavailable RPC listener: startup emits output before job events.
local serverstart = vim.fn.serverstart
vim.fn.serverstart = function()
  error("test RPC unavailable")
end
local bufnr, err = ark.console()
vim.fn.serverstart = serverstart
if not bufnr then
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end


local original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
assert(original[1]:find("failed to start Ark console RPC server", 1, true))
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "tampered startup output" })
ark_test.wait_for("startup transcript restored", 3000, function()
  return vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
end)
stop_watchdog()
