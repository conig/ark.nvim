local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_argument_string_completion.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  'cor(mtcars, method = "',
  'mean(mtcars$mpg, trim = "',
})

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local trigger_characters = (((client.server_capabilities or {}).completionProvider or {}).triggerCharacters) or {}

if not vim.tbl_contains(trigger_characters, '"') then
  ark_test.fail('ark_lsp completion triggers missing double quote: ' .. vim.inspect(trigger_characters))
end

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params))
end

local method_items = completion_at(1, #lines[1])
for _, label in ipairs({ "pearson", "kendall", "spearman" }) do
  local item = ark_test.find_item(method_items, label)
  if not item then
    ark_test.fail('cor(mtcars, method = " completion missing ' .. label .. ': ' .. vim.inspect(ark_test.item_labels(method_items)))
  end
  if ark_test.insert_text(item) ~= label then
    ark_test.fail('cor(mtcars, method = " completion inserted unexpected text: ' .. vim.inspect(item))
  end
end

local trim_items = completion_at(2, #lines[2])
if #trim_items ~= 0 then
  ark_test.fail('mean(mtcars$mpg, trim = " completion expected no string choices: ' .. vim.inspect(ark_test.item_labels(trim_items)))
end

vim.print({
  method = "ok",
  trim = "ok",
})
