vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_help_rpc")

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

local help_calls = {}
local original_help_topic = ark.help_topic
ark.help_topic = function(topic, bufnr)
  help_calls[#help_calls + 1] = {
    topic = topic,
    bufnr = bufnr,
  }
  return topic, nil
end

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end

local fn = _G.__ark_console_rpc_ark_help
if type(fn) ~= "function" then
  ark_test.fail("Ark console help RPC function was not registered")
end

local result = fn("lm")
if result ~= "ok" then
  ark_test.fail("Ark console help RPC should return ok, got " .. vim.inspect(result))
end

ark_test.wait_for("Ark console help RPC dispatch", 5000, function()
  return #help_calls == 1
end)

if help_calls[1].topic ~= "lm" or help_calls[1].bufnr ~= bufnr then
  ark_test.fail("unexpected ArkHelp RPC dispatch: " .. vim.inspect(help_calls))
end

ark.help_topic = original_help_topic

vim.print({
  nvim_console_help_rpc = "ok",
})

stop_watchdog()
