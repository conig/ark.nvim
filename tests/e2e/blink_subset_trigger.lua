local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  ark_test.fail("blink.cmp is required for this test")
end

local list = require("blink.cmp.completion.list")
local ark_blink = require("ark.blink")

local test_file = "/tmp/ark_blink_subset_trigger.R"

local pane_id = ark_test.setup_managed_buffer(test_file, {
  "dt_ark[]",
  "dt_ark[,.()]",
  "dt_ark[, .(mpg, )]",
})

local has_data_table = ark_test.probe_data_table_available(
  pane_id,
  'ark_dt_available <- requireNamespace("data.table", quietly = TRUE); if (ark_dt_available) dt_ark <- data.table::as.data.table(mtcars)'
)

if not has_data_table then
  ark_test.fail("data.table package not available")
end

local function wait_for_item(label)
  ark_test.wait_for("blink completion item " .. label, 4000, function()
    if not blink.is_visible() then
      return false
    end

    return ark_test.find_item(list.items, label) ~= nil
  end)
end

local function show_pair_completion(line, column, trigger_character, label)
  vim.api.nvim_win_set_cursor(0, { line, column })
  vim.cmd("startinsert")
  vim.b.ark_pending_pair_completion = trigger_character
  ark_blink.maybe_show_after_pair(0)
  wait_for_item(label)
  blink.hide()
  vim.cmd("stopinsert")
end

local function show_trigger_completion(line, column, trigger_character, label)
  vim.api.nvim_win_set_cursor(0, { line, column })
  vim.cmd("startinsert")
  require("blink.cmp.completion.trigger").show({
    trigger_kind = "trigger_character",
    trigger_character = trigger_character,
  })
  wait_for_item(label)
  blink.hide()
  vim.cmd("stopinsert")
end

show_pair_completion(1, 7, "[", "mpg")
show_pair_completion(2, 10, "(", "mpg")
show_trigger_completion(3, 16, " ", "cyl")

vim.print({
  dt_subset_pair = true,
  dt_compact_j_pair = true,
  dt_after_space = true,
})
