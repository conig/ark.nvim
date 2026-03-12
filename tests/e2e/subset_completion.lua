local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_subset_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "mtcars[",
  'mtcars[, c("',
  'mtcars[["',
  "dt_ark[",
  "dt_ark[]",
  "dt_ark[as.char",
  "dt_ark[,.()]",
  "dt_ark[, .()]",
  "dt_ark[, .(m",
  "dt_ark[, .(m)]",
  "dt_ark[, .(mpg, )]",
  "dt_ark[, list()]",
  "dt_ark[, list(mpg,)]",
})

local has_data_table = ark_test.probe_data_table_available(
  pane_id,
  'ark_dt_available <- requireNamespace("data.table", quietly = TRUE); if (ark_dt_available) dt_ark <- data.table::as.data.table(mtcars)'
)

local function completion_at(line, column, trigger_character)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  if trigger_character then
    params.context = {
      triggerKind = 2,
      triggerCharacter = trigger_character,
    }
  end
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params))
end

local trigger_characters = (((client.server_capabilities or {}).completionProvider or {}).triggerCharacters) or {}

if not vim.tbl_contains(trigger_characters, "(") then
  ark_test.fail('ark_lsp completion triggers missing left paren: ' .. vim.inspect(trigger_characters))
end
if not vim.tbl_contains(trigger_characters, "[") then
  ark_test.fail('ark_lsp completion triggers missing left bracket: ' .. vim.inspect(trigger_characters))
end
if not vim.tbl_contains(trigger_characters, ",") then
  ark_test.fail('ark_lsp completion triggers missing comma: ' .. vim.inspect(trigger_characters))
end
if not vim.tbl_contains(trigger_characters, " ") then
  ark_test.fail('ark_lsp completion triggers missing space: ' .. vim.inspect(trigger_characters))
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

  local dt_subset_pair_items = completion_at(5, 7, "[")
  local dt_subset_pair = ark_test.find_item(dt_subset_pair_items, "mpg")
  if not dt_subset_pair then
    ark_test.fail("dt_ark[] completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_subset_pair_items)))
  end
  if type(dt_subset_pair.sortText) ~= "string" or not dt_subset_pair.sortText:match("^0%-") then
    ark_test.fail("dt_ark[] completion did not hoist mpg with priority sortText: " .. vim.inspect(dt_subset_pair))
  end
  if ark_test.insert_text(dt_subset_pair) ~= "mpg" then
    ark_test.fail("dt_ark[] completion inserted unexpected text: " .. vim.inspect(dt_subset_pair))
  end
  result.dt_subset_pair = ark_test.insert_text(dt_subset_pair)

  local dt_symbol_items = completion_at(6, 14)
  local dt_symbol = ark_test.find_item(dt_symbol_items, "as.character")
  if not dt_symbol then
    ark_test.fail("dt_ark[as.char completion missing as.character: " .. vim.inspect(ark_test.item_labels(dt_symbol_items)))
  end
  result.dt_symbol = ark_test.insert_text(dt_symbol)

  local dt_compact_open_j_items = completion_at(7, 10, "(")
  local dt_compact_open_j = ark_test.find_item(dt_compact_open_j_items, "mpg")
  if not dt_compact_open_j then
    ark_test.fail("dt_ark[,.()] completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_compact_open_j_items)))
  end
  if type(dt_compact_open_j.sortText) ~= "string" or not dt_compact_open_j.sortText:match("^0%-") then
    ark_test.fail("dt_ark[,.()] completion did not hoist mpg with priority sortText: " .. vim.inspect(dt_compact_open_j))
  end
  if ark_test.insert_text(dt_compact_open_j) ~= "mpg" then
    ark_test.fail("dt_ark[,.()] completion inserted unexpected text: " .. vim.inspect(dt_compact_open_j))
  end
  result.dt_compact_open_j = ark_test.insert_text(dt_compact_open_j)

  local dt_open_j_items = completion_at(8, 11)
  local dt_open_j = ark_test.find_item(dt_open_j_items, "mpg")
  if not dt_open_j then
    ark_test.fail("dt_ark[, .()] completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_open_j_items)))
  end
  if type(dt_open_j.sortText) ~= "string" or not dt_open_j.sortText:match("^0%-") then
    ark_test.fail("dt_ark[, .()] completion did not hoist mpg with priority sortText: " .. vim.inspect(dt_open_j))
  end
  if ark_test.insert_text(dt_open_j) ~= "mpg" then
    ark_test.fail("dt_ark[, .()] completion inserted unexpected text: " .. vim.inspect(dt_open_j))
  end
  result.dt_open_j = ark_test.insert_text(dt_open_j)

  local dt_j_items = completion_at(9, 12)
  local dt_j = ark_test.find_item(dt_j_items, "mpg")
  if not dt_j then
    ark_test.fail("dt_ark[, .(m completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_j_items)))
  end
  if type(dt_j.sortText) ~= "string" or not dt_j.sortText:match("^0%-") then
    ark_test.fail("dt_ark[, .(m completion did not hoist mpg with priority sortText: " .. vim.inspect(dt_j))
  end
  if ark_test.insert_text(dt_j) ~= "mpg" then
    ark_test.fail("dt_ark[, .(m completion inserted unexpected text: " .. vim.inspect(dt_j))
  end
  result.dt_j = ark_test.insert_text(dt_j)

  local dt_closed_j_items = completion_at(10, 12)
  local dt_closed_j = ark_test.find_item(dt_closed_j_items, "mpg")
  if not dt_closed_j then
    ark_test.fail("dt_ark[, .(m)] completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_closed_j_items)))
  end
  if type(dt_closed_j.sortText) ~= "string" or not dt_closed_j.sortText:match("^0%-") then
    ark_test.fail("dt_ark[, .(m)] completion did not hoist mpg with priority sortText: " .. vim.inspect(dt_closed_j))
  end
  if ark_test.insert_text(dt_closed_j) ~= "mpg" then
    ark_test.fail("dt_ark[, .(m)] completion inserted unexpected text: " .. vim.inspect(dt_closed_j))
  end
  result.dt_closed_j = ark_test.insert_text(dt_closed_j)

  local dt_after_space_items = completion_at(11, 16, " ")
  local dt_after_space = ark_test.find_item(dt_after_space_items, "cyl")
  if not dt_after_space then
    ark_test.fail("dt_ark[, .(mpg, ) completion missing cyl: " .. vim.inspect(ark_test.item_labels(dt_after_space_items)))
  end
  if type(dt_after_space.sortText) ~= "string" or not dt_after_space.sortText:match("^0%-") then
    ark_test.fail("dt_ark[, .(mpg, ) completion did not hoist cyl with priority sortText: " .. vim.inspect(dt_after_space))
  end
  if ark_test.insert_text(dt_after_space) ~= "cyl" then
    ark_test.fail("dt_ark[, .(mpg, ) completion inserted unexpected text: " .. vim.inspect(dt_after_space))
  end
  result.dt_after_space = ark_test.insert_text(dt_after_space)

  local dt_list_open_items = completion_at(12, 14)
  local dt_list_open = ark_test.find_item(dt_list_open_items, "mpg")
  if not dt_list_open then
    ark_test.fail("dt_ark[, list()] completion missing mpg: " .. vim.inspect(ark_test.item_labels(dt_list_open_items)))
  end
  if type(dt_list_open.sortText) ~= "string" or not dt_list_open.sortText:match("^0%-") then
    ark_test.fail("dt_ark[, list()] completion did not hoist mpg with priority sortText: " .. vim.inspect(dt_list_open))
  end
  if ark_test.insert_text(dt_list_open) ~= "mpg" then
    ark_test.fail("dt_ark[, list()] completion inserted unexpected text: " .. vim.inspect(dt_list_open))
  end
  result.dt_list_open = ark_test.insert_text(dt_list_open)

  local dt_list_after_items = completion_at(13, 18)
  local dt_list_after = ark_test.find_item(dt_list_after_items, "cyl")
  if not dt_list_after then
    ark_test.fail("dt_ark[, list(mpg,)] completion missing cyl: " .. vim.inspect(ark_test.item_labels(dt_list_after_items)))
  end
  if type(dt_list_after.sortText) ~= "string" or not dt_list_after.sortText:match("^0%-") then
    ark_test.fail("dt_ark[, list(mpg,)] completion did not hoist cyl with priority sortText: " .. vim.inspect(dt_list_after))
  end
  if ark_test.insert_text(dt_list_after) ~= "cyl" then
    ark_test.fail("dt_ark[, list(mpg,)] completion inserted unexpected text: " .. vim.inspect(dt_list_after))
  end
  result.dt_list_after = ark_test.insert_text(dt_list_after)
else
  result.dt_subset = "skipped"
  result.dt_subset_pair = "skipped"
  result.dt_symbol = "skipped"
  result.dt_compact_open_j = "skipped"
  result.dt_open_j = "skipped"
  result.dt_j = "skipped"
  result.dt_closed_j = "skipped"
  result.dt_after_space = "skipped"
  result.dt_list_open = "skipped"
  result.dt_list_after = "skipped"
end

vim.print(result)
