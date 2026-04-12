local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_library_empty_completion.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  "library(",
})

local trigger_characters = (((client.server_capabilities or {}).completionProvider or {}).triggerCharacters) or {}

if not vim.tbl_contains(trigger_characters, "(") then
  ark_test.fail('ark_lsp completion triggers missing left paren: ' .. vim.inspect(trigger_characters))
end

local function completion_result_at(line, column, trigger_kind, trigger_character)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }

  if trigger_kind then
    params.context = {
      triggerKind = trigger_kind,
      triggerCharacter = trigger_character,
    }
  end

  return ark_test.request(client, "textDocument/completion", params)
end

-- Mirror the editor autopopup case: typing `library(` should not open a menu
-- full of installed packages before the user has typed any package prefix.
local trigger_result = completion_result_at(1, 8, 2, "(")
if trigger_result ~= nil then
  ark_test.fail("library( trigger completion should be suppressed, got: " .. vim.inspect(ark_test.completion_items(trigger_result)))
end

-- Explicit completion at the same cursor position should still offer package
-- names for users who ask for them intentionally.
local explicit_items = ark_test.completion_items(completion_result_at(1, 8, 1))
if #explicit_items == 0 then
  ark_test.fail("library( explicit completion unexpectedly returned no items")
end

local module_kind = vim.lsp.protocol.CompletionItemKind.Module
for index = 1, math.min(#explicit_items, 10) do
  local item = explicit_items[index]
  if item.kind ~= module_kind then
    ark_test.fail("library( explicit completion returned a non-package item: " .. vim.inspect(item))
  end
  if ark_test.insert_text(item) ~= item.label then
    ark_test.fail("library( explicit completion inserted unexpected text: " .. vim.inspect(item))
  end
end

vim.print({
  explicit_completion_count = #explicit_items,
  first_label = explicit_items[1].label,
})
