vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_view_rpc")

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
  view = {
    display = "tmux_popup",
    popup = {
      width = "91%",
      height = "83%",
    },
  },
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local view_calls = {}
local original_view_popup = ark.view_popup
ark.view_popup = function(expr, bufnr)
  view_calls[#view_calls + 1] = {
    expr = expr,
    bufnr = bufnr,
  }
  return true, nil
end

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end

local fn = _G.__ark_console_rpc_ark_view
if type(fn) ~= "function" then
  ark_test.fail("Ark console View RPC function was not registered")
end

local result = fn("mtcars")
if result ~= "ok" then
  ark_test.fail("Ark console View RPC should return ok, got " .. vim.inspect(result))
end

ark_test.wait_for("Ark console View RPC dispatch", 5000, function()
  return #view_calls == 1
end)

if view_calls[1].expr ~= "mtcars" or view_calls[1].bufnr ~= bufnr then
  ark_test.fail("unexpected ArkView RPC dispatch: " .. vim.inspect(view_calls))
end

ark.view_popup = original_view_popup

vim.print({
  nvim_console_view_rpc = "ok",
})

stop_watchdog()
