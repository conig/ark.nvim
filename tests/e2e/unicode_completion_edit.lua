local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_unicode_completion_edit.R"
local source = '"😃"; debug(utils::adist)'

local _, client = ark_test.setup_managed_buffer(test_file, { source })

ark_test.wait_for("detached ark_lsp hydration", 10000, function()
  local status = require("ark").status({ include_lsp = true })
  local lsp_status = status and status.lsp_status or nil
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

local prefix = '"😃"; debug(utils::'
local byte_column = #prefix
local utf16_column = vim.str_utfindex(prefix, "utf-16")
vim.api.nvim_win_set_cursor(0, { 1, byte_column })

local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
params.context = {
  triggerKind = vim.lsp.protocol.CompletionTriggerKind.Invoked,
}

if byte_column == utf16_column or params.position.character ~= utf16_column then
  ark_test.fail("Unicode-prefixed request did not exercise UTF-16/byte conversion: " .. vim.inspect({
    request_position = params.position,
    byte_column = byte_column,
    utf16_column = utf16_column,
  }))
end

local result = ark_test.request(client, "textDocument/completion", params)
local item = ark_test.find_item(ark_test.completion_items(result), "adist")
if not item then
  ark_test.fail("Unicode-prefixed completion missing adist: " .. vim.inspect(result))
end

local text_edit = item.textEdit or item.text_edit
if not text_edit then
  ark_test.fail("Unicode-prefixed completion missing text edit: " .. vim.inspect(item))
end

local range = text_edit.range
if range.start.line ~= 0
  or range.start.character ~= params.position.character
  or range["end"].line ~= 0
  or range["end"].character ~= params.position.character + #"adist"
then
  ark_test.fail("Unicode-prefixed completion returned the wrong UTF-16 range: " .. vim.inspect({
    request_position = params.position,
    range = range,
  }))
end

vim.lsp.util.apply_text_edits({ text_edit }, vim.api.nvim_get_current_buf(), client.offset_encoding)
local edited = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
if edited ~= source then
  ark_test.fail("Unicode-prefixed completion corrupted the buffer: " .. vim.inspect({
    expected = source,
    actual = edited,
    text_edit = text_edit,
  }))
end

vim.print({
  request_position = params.position,
  byte_column = byte_column,
  utf16_column = utf16_column,
  text_edit = text_edit,
  edited = edited,
})
