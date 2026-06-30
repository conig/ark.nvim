vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_help_parent_rpc")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  configure_slime = false,
})

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_help_parent_rpc.R")
vim.bo[source_buf].filetype = "r"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "lm" })

local calls = {}
local original_help_topic = ark.help_topic
ark.help_topic = function(topic, bufnr)
  calls[#calls + 1] = {
    topic = topic,
    bufnr = bufnr,
  }
  return topic, nil
end

local fn = _G.__ark_nvim_help_rpc
if type(fn) ~= "function" then
  ark_test.fail("parent ArkHelp RPC function was not registered")
end

local result = fn("lm")
if result ~= "ok" then
  ark_test.fail("parent ArkHelp RPC should return ok, got " .. vim.inspect(result))
end

ark_test.wait_for("parent ArkHelp RPC dispatch", 5000, function()
  return #calls == 1
end)

if calls[1].topic ~= "lm" or calls[1].bufnr ~= source_buf then
  ark_test.fail("unexpected parent ArkHelp RPC dispatch: " .. vim.inspect(calls))
end

ark.help_topic = original_help_topic

vim.print({
  ark_help_parent_rpc = "ok",
})

stop_watchdog()
