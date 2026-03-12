local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_subset_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "mtcars[",
  'mtcars[, c("',
  'mtcars[["',
  "dt_ark[",
  "dt_ark[as.char",
  "dt_ark[, .(m",
})

local has_data_table = ark_test.probe_data_table_available(
  pane_id,
  'ark_dt_available <- requireNamespace("data.table", quietly = TRUE); if (ark_dt_available) dt_ark <- data.table::as.data.table(mtcars)'
)

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params))
end

local df_subset_items = completion_at(1, 7)
local df_subset = ark_test.find_item(df_subset_items, "mpg")
if not df_subset then
  ark_test.fail("mtcars[ completion missing mpg: " .. vim.inspect(ark_test.item_labels(df_subset_items)))
end
if ark_test.insert_text(df_subset) ~= '"mpg"' then
  ark_test.fail("mtcars[ completion inserted unexpected text: " .. vim.inspect(df_subset))
end

local df_string_subset_items = completion_at(2, 12)
local df_string_subset = ark_test.find_item(df_string_subset_items, "mpg")
if not df_string_subset then
  ark_test.fail('mtcars[, c(" completion missing mpg: ' .. vim.inspect(ark_test.item_labels(df_string_subset_items)))
end
if ark_test.insert_text(df_string_subset) ~= "mpg" then
  ark_test.fail('mtcars[, c(" completion inserted unexpected text: ' .. vim.inspect(df_string_subset))
end

local df_subset2_items = completion_at(3, 9)
local df_subset2 = ark_test.find_item(df_subset2_items, "mpg")
if not df_subset2 then
  ark_test.fail('mtcars[[" completion missing mpg: ' .. vim.inspect(ark_test.item_labels(df_subset2_items)))
end
if ark_test.insert_text(df_subset2) ~= "mpg" then
  ark_test.fail('mtcars[[" completion inserted unexpected text: ' .. vim.inspect(df_subset2))
end

local result = {
  mtcars_subset = ark_test.insert_text(df_subset),
  mtcars_string_subset = ark_test.insert_text(df_string_subset),
  mtcars_subset2 = ark_test.insert_text(df_subset2),
}

if has_data_table then
  local dt_subset_items = completion_at(4, 7)
  local dt_subset = ark_test.find_item(dt_subset_items, "mpg")
  if not dt_subset then
    ark_test.fail("dt_ark[ completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_subset_items)))
  end
  if ark_test.insert_text(dt_subset) ~= "mpg" then
    ark_test.fail("dt_ark[ completion inserted unexpected text: " .. vim.inspect(dt_subset))
  end
  result.dt_subset = ark_test.insert_text(dt_subset)

  local dt_symbol_items = completion_at(5, 14)
  local dt_symbol = ark_test.find_item(dt_symbol_items, "as.character")
  if not dt_symbol then
    ark_test.fail("dt_ark[as.char completion missing as.character: " .. vim.inspect(ark_test.item_labels(dt_symbol_items)))
  end
  result.dt_symbol = ark_test.insert_text(dt_symbol)

  local dt_j_items = completion_at(6, 12)
  local dt_j = ark_test.find_item(dt_j_items, "mpg")
  if not dt_j then
    ark_test.fail("dt_ark[, .(m completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_j_items)))
  end
  if ark_test.insert_text(dt_j) ~= "mpg" then
    ark_test.fail("dt_ark[, .(m completion inserted unexpected text: " .. vim.inspect(dt_j))
  end
  result.dt_j = ark_test.insert_text(dt_j)
else
  result.dt_subset = "skipped"
  result.dt_symbol = "skipped"
  result.dt_j = "skipped"
end

vim.print(result)
