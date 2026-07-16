vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local layout = require("ark.view_layout")
local paging = require("ark.view_paging")

local function expect_equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    ark_test.fail(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)))
  end
end

expect_equal(layout.sidebar_split_width(60), 12, "narrow sidebar width")
expect_equal(layout.sidebar_split_width(132), 26, "standard sidebar width")
expect_equal(paging.virtual_row_limit(38), 160, "minimum virtual row window")
expect_equal(paging.virtual_row_limit(120), 400, "maximum virtual row window")

local tall_state = {
  total_rows = 10000,
  requested_page_limit = 0,
  virtual_rows_allowed = true,
}
expect_equal(paging.row_request_limit(tall_state, 38), 160, "automatic virtual row request")
expect_equal(tall_state.virtual_rows, true, "automatic virtualization state")
expect_equal(paging.max_page_offset(tall_state, 160), 9840, "last virtual row offset")
expect_equal(paging.normalize_page_offset(tall_state, 9999, 160), 9840, "clamped virtual row offset")

tall_state.requested_page_limit = 25
expect_equal(paging.row_request_limit(tall_state, 38), 25, "explicit page request")
expect_equal(tall_state.virtual_rows, false, "explicit paging disables virtualization")

local cell_reads = 0
local function counted_row(values)
  return setmetatable({}, {
    __index = function(_, key)
      cell_reads = cell_reads + 1
      return values[tonumber(key)]
    end,
  })
end

local state = {
  schema = {
    { index = 1, name = "alpha", class = "character" },
    { index = 2, name = "beta", class = "character" },
    { index = 3, name = "gamma", class = "character" },
  },
  rows = {
    counted_row({ "one", "a much wider value", "three" }),
    counted_row({ "four", "five", "six" }),
  },
  selected_column = 2,
  column_width_overrides = {},
}

local visible, widths, positions = layout.visible_grid_columns(state, 4, 140)
expect_equal(#visible, 3, "visible schema size")
expect_equal(positions, { 1, 2, 3 }, "visible schema order")
expect_equal(widths[2], #"a much wider value", "measured cell width")
expect_equal(layout.pinned_column_width(state, 2, 4, 40), 12, "automatic pinned width fits viewport")
if cell_reads == 0 then
  ark_test.fail("initial layout did not measure loaded cell values")
end

local reads_after_first_layout = cell_reads
layout.visible_grid_columns(state, 4, 140)
expect_equal(cell_reads, reads_after_first_layout, "unchanged page width cache")

state.rows = {
  counted_row({ "seven", "eight", "a new widest value" }),
}
layout.visible_grid_columns(state, 4, 140)
if cell_reads <= reads_after_first_layout then
  ark_test.fail("replacing page rows did not invalidate cached width measurements")
end

state.pinned_column = 2
local columns = layout.page_columns(state, 4, 140)
expect_equal(columns, { 1, 2, 3 }, "page projection deduplicates pinned column")
state.column_width_overrides[2] = 50
expect_equal(layout.pinned_column_width(state, 2, 4, 40), 50, "explicit pinned width is preserved")
expect_equal(layout.page_includes_column({ page_columns = columns }, 2), true, "loaded page column")
expect_equal(layout.page_includes_column({ page_columns = columns }, 8), false, "unloaded page column")

vim.print({
  view_layout_policy = "ok",
  first_layout_cell_reads = reads_after_first_layout,
  refreshed_cell_reads = cell_reads,
})
