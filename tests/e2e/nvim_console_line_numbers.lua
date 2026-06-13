vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_line_numbers")

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

local winid = vim.fn.bufwinid(bufnr)
if type(winid) ~= "number" or winid <= 0 then
  ark_test.fail("console buffer is not visible")
end
vim.api.nvim_set_current_win(winid)

local function wait_for_numbers(label, number, relativenumber)
  ark_test.wait_for(label, 5000, function()
    return vim.wo[winid].number == number and vim.wo[winid].relativenumber == relativenumber
  end)
end

wait_for_numbers("console normal mode shows relative line numbers", true, true)

vim.api.nvim_exec_autocmds("InsertEnter", {})
wait_for_numbers("console insert mode hides line numbers", false, false)

vim.api.nvim_exec_autocmds("InsertLeave", {})
wait_for_numbers("console normal mode restores relative line numbers", true, true)

vim.print({
  nvim_console_line_numbers = "ok",
})

stop_watchdog()
