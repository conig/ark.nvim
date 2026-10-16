vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_help_rpc")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf 'fake-r-ready\\n> '",
  "while IFS= read -r line; do",
  '  if [[ "$line" == slow ]]; then sleep 0.3; fi',
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

local console = require("ark.console")
ark_test.wait_for("initial console prompt", 5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  return text:find("#> fake-r-ready", 1, true) and console.status(bufnr).prompt_state == "top-level"
end)
assert(console.send_text(bufnr, "slow"))
assert(fn("citation") == "ok", "busy help RPC must acknowledge R without waiting for its prompt")
vim.wait(100, function()
  return false
end)
assert(#help_calls == 1, "busy console must not query help before its prompt returns")
ark_test.wait_for("queued help after prompt", 5000, function()
  return #help_calls == 2
end)
assert(help_calls[2].topic == "citation" and help_calls[2].bufnr == bufnr)
assert(console.status(bufnr).prompt_state == "top-level")

-- Closing the session must discard help callbacks that are still waiting.
assert(console.send_text(bufnr, "slow"))
assert(fn("mean") == "ok")
assert(console.stop(bufnr))
vim.wait(500, function()
  return false
end)
assert(#help_calls == 2, "stopped console must not dispatch queued or duplicate help")

ark.help_topic = original_help_topic

vim.print({
  nvim_console_help_rpc = "ok",
})

stop_watchdog()
