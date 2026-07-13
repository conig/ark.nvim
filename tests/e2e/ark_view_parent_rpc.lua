vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_view_parent_rpc")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  configure_slime = false,
  view = {
    display = "tmux_popup",
    popup = {
      width = "89%",
      height = "81%",
    },
  },
})

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_parent_rpc.R")
vim.bo[source_buf].filetype = "r"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

local calls = {}
local original_view = ark.view
ark.view = function(expr, bufnr)
  calls[#calls + 1] = {
    expr = expr,
    bufnr = bufnr,
  }
  return true, nil
end

local fn = _G.__ark_nvim_view_rpc
if type(fn) ~= "function" then
  ark_test.fail("parent ArkView RPC function was not registered")
end

local result = fn("mtcars")
if result ~= "ok" then
  ark_test.fail("parent ArkView RPC should return ok, got " .. vim.inspect(result))
end

ark_test.wait_for("parent ArkView RPC dispatch", 5000, function()
  return #calls == 1
end)

if calls[1].expr ~= "mtcars" or calls[1].bufnr ~= source_buf then
  ark_test.fail("unexpected parent ArkView RPC dispatch: " .. vim.inspect(calls))
end

ark.view = original_view

vim.print({
  ark_view_parent_rpc = "ok",
})

stop_watchdog()
