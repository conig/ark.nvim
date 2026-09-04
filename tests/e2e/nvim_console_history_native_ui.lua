vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_history_native_ui")

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

draft("first_call()")
assert(console.submit(bufnr))
ark_test.wait_for("first output", 4000, function()
  return console.status(bufnr).prompt_state == "top-level"
end)
draft("second_call()")
assert(console.submit(bufnr))
ark_test.wait_for("second output", 4000, function()
  return console.status(bufnr).prompt_state == "top-level"
end)
draft("keep_this_draft()")


-- Exercise Neovim's actual input/select fallback, without a picker plugin.
vim.defer_fn(function()
  vim.api.nvim_input("first\r")
  vim.defer_fn(function()
    vim.api.nvim_input("1\r")
  end, 100)
end, 100)
assert(console.history_search(bufnr))
ark_test.wait_for("native picker recalled command", 4000, function()
  return input() == "first_call()"
end)
assert(#console.status(bufnr).history == 2, "native picker executed a command")
stop_watchdog()
