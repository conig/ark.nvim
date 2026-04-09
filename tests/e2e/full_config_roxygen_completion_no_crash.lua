local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  ark_test.fail("blink.cmp is required for this test")
end

local list = require("blink.cmp.completion.list")
local test_file = "/tmp/ark_full_config_roxygen_completion_no_crash.R"

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function current_status()
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end

  return ark.status({ include_lsp = true })
end

local function roxygen_labels_at_cursor()
  local client = current_client()
  if not client or client:is_stopped() then
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
      triggerKind = 2,
      triggerCharacter = "@",
    },
  }, 10000, 0)

  if not response or response.error or response.err then
    return {}
  end

  return ark_test.item_labels(ark_test.completion_items(response.result))
end

local function stop_insert_mode()
  if vim.fn.mode() == "i" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    ark_test.wait_for("normal mode", 4000, function()
      return vim.fn.mode() == "n"
    end)
  end
end

local function item_index(label)
  for index, item in ipairs(list.items) do
    if item.label == label then
      return index
    end
  end
end

vim.fn.writefile({ "" }, test_file)
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

ark_test.wait_for("ark lsp hydrated", 30000, function()
  local status = current_status()
  local lsp_status = status and status.lsp_status or nil
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

-- This mirrors the reported full-config workflow: type a roxygen tag trigger
-- and require both a live client and roxygen tag completions.
blink.hide()
stop_insert_mode()
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "#' @",
  "foo <- function(x) {",
  "  x",
  "}",
})
vim.api.nvim_win_set_cursor(0, { 1, 4 })

vim.wait(1500, function()
  return false
end, 50, false)

local client = current_client()
local labels = roxygen_labels_at_cursor()
local blink_visible = blink.is_visible()
local blink_labels = vim.tbl_map(function(item)
  return item.label
end, list.items)
local status = current_status()

blink.hide()
stop_insert_mode()

if not client or client:is_stopped() or not vim.tbl_contains(labels, "description") then
  ark_test.fail(vim.inspect({
    client = client and {
      id = client.id,
      initialized = client.initialized,
      stopped = client.is_stopped and client:is_stopped() or false,
      name = client.name,
    } or nil,
    labels = labels,
    blink_visible = blink_visible,
    blink_labels = blink_labels,
    blink_found_description = item_index("description") ~= nil,
    line = vim.api.nvim_get_current_line(),
    cursor = vim.api.nvim_win_get_cursor(0),
    status = status,
  }))
end

vim.print({
  labels = labels,
  blink_visible = blink_visible,
  blink_labels = blink_labels,
  status = status,
})
