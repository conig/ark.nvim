local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  ark_test.fail("blink.cmp is required for this test")
end

local list = require("blink.cmp.completion.list")
local trigger = require("blink.cmp.completion.trigger")

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function completion_labels_at_cursor()
  local client = current_client()
  if not client then
    return {}
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local response = client:request_sync("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = {
      line = cursor[1] - 1,
      character = cursor[2],
    },
    context = {
      triggerKind = 1,
    },
  }, 10000, 0)

  if not response or response.error or response.err then
    return {}
  end

  return ark_test.item_labels(ark_test.completion_items(response.result))
end

local function current_status()
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end

  return ark.status({ include_lsp = true })
end

local test_file = "/tmp/ark_indented_open_line.R"

vim.fn.writefile({
  "fn <- function(){",
  "  x = 1",
  "browser()",
  "}",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

ark_test.wait_for("R filetype", 10000, function()
  return vim.bo.filetype == "r"
end)

ark_test.wait_for("ark plugin load", 15000, function()
  return package.loaded["ark"] ~= nil
end)

ark_test.wait_for("ark bridge ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.repl_ready == true
end)

ark_test.wait_for("ark lsp client", 30000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

blink.hide()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys("o", "xt", false)

ark_test.wait_for("opened line", 4000, function()
  local cursor = vim.api.nvim_win_get_cursor(0)
  return cursor[1] == 3 and vim.api.nvim_get_current_line() == ""
end)

vim.api.nvim_set_current_line("\t\t")
local line = vim.api.nvim_get_current_line()
vim.api.nvim_win_set_cursor(0, { 3, #line })

vim.wait(500, function()
  return false
end, 50, false)

trigger.show({ trigger_kind = "keyword" })
vim.wait(750, function()
  return false
end, 50, false)

local lsp_labels = completion_labels_at_cursor()
local blink_labels = vim.tbl_map(function(item)
  return item.label
end, list.items)
local blink_sources = vim.tbl_map(function(item)
  return {
    label = item.label,
    source_id = item.source_id,
    client_name = item.client_name,
  }
end, list.items)

local result = {
  blink_visible = blink.is_visible(),
  blink_labels = blink_labels,
  blink_sources = blink_sources,
  lsp_labels = lsp_labels,
  cursor = vim.api.nvim_win_get_cursor(0),
  line = line,
}

blink.hide()

if result.blink_visible or #result.lsp_labels > 0 then
  ark_test.fail(vim.inspect(result))
end

vim.print(result)
