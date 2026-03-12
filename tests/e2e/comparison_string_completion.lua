local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_comparison_string_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  'colors_ark == "a',
  'levels_ark != "b',
  'dt_cmp_ark[color == "a',
  'mtcars$cyl == "4',
  'iris$Species == "',
})

local has_data_table = ark_test.probe_data_table_available(
  pane_id,
  'colors_ark <- c("apple", "banana", "apricot"); levels_ark <- factor(c("beta", "banana", "berry")); ark_dt_available <- requireNamespace("data.table", quietly = TRUE); if (ark_dt_available) dt_cmp_ark <- data.table::data.table(color = c("apple", "banana", "apricot"))'
)

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

local colors_items = completion_at(1, #lines[1])
local apple = ark_test.find_item(colors_items, "apple")
if not apple then
  ark_test.fail('colors_ark == " completion missing apple: ' .. vim.inspect(ark_test.item_labels(colors_items)))
end
if ark_test.insert_text(apple) ~= "apple" then
  ark_test.fail('colors_ark == " completion inserted unexpected text: ' .. vim.inspect(apple))
end

local levels_items = completion_at(2, #lines[2])
local banana = ark_test.find_item(levels_items, "banana")
if not banana then
  ark_test.fail('levels_ark != " completion missing banana: ' .. vim.inspect(ark_test.item_labels(levels_items)))
end
if ark_test.insert_text(banana) ~= "banana" then
  ark_test.fail('levels_ark != " completion inserted unexpected text: ' .. vim.inspect(banana))
end

local result = {
  colors = ark_test.insert_text(apple),
  levels = ark_test.insert_text(banana),
}

if has_data_table then
  local dt_items = completion_at(3, #lines[3])
  local dt_apple = ark_test.find_item(dt_items, "apple")
  if not dt_apple then
    ark_test.fail('dt_cmp_ark[color == " completion missing apple: ' .. vim.inspect(ark_test.item_labels(dt_items)))
  end
  if ark_test.insert_text(dt_apple) ~= "apple" then
    ark_test.fail('dt_cmp_ark[color == " completion inserted unexpected text: ' .. vim.inspect(dt_apple))
  end
  result.data_table = ark_test.insert_text(dt_apple)
else
  result.data_table = "skipped"
end

local numeric_items = completion_at(4, #lines[4])
if #numeric_items ~= 0 then
  ark_test.fail('mtcars$cyl == " completion expected no string completions: ' .. vim.inspect(ark_test.item_labels(numeric_items)))
end
result.numeric = "ok"

local iris_items = completion_at(5, #lines[5])
local setosa = ark_test.find_item(iris_items, "setosa")
if not setosa then
  ark_test.fail('iris$Species == " completion missing setosa: ' .. vim.inspect(ark_test.item_labels(iris_items)))
end
if ark_test.insert_text(setosa) ~= "setosa" then
  ark_test.fail('iris$Species == " completion inserted unexpected text: ' .. vim.inspect(setosa))
end
result.iris = ark_test.insert_text(setosa)

vim.print(result)
