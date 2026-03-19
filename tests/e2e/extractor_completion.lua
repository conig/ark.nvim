local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_extractor_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "mtcars$",
  "mtcars$mp",
})

local function completion_at(line, column, trigger_character)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = {
      triggerKind = 2,
      triggerCharacter = trigger_character,
    },
  }

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params))
end

local empty_rhs_items = completion_at(1, 7, "$")
local empty_rhs = ark_test.find_item(empty_rhs_items, "mpg")
if not empty_rhs then
  ark_test.fail("mtcars$ completion missing mpg: " .. vim.inspect(ark_test.item_labels(empty_rhs_items)))
end

local prefixed_rhs_items = completion_at(2, 9, "$")
local prefixed_rhs = ark_test.find_item(prefixed_rhs_items, "mpg")
if not prefixed_rhs then
  ark_test.fail("mtcars$mp completion missing mpg: " .. vim.inspect(ark_test.item_labels(prefixed_rhs_items)))
end

vim.print({
  mtcars_dollar = ark_test.insert_text(empty_rhs),
  mtcars_dollar_prefixed = ark_test.insert_text(prefixed_rhs),
})
