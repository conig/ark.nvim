local ark_test = require("ark_test")
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local snacks = require("snacks")
snacks.setup({ picker = { enabled = true } })

local buffer_path = ark_test.run_tmpdir() .. "/value-search.R"
ark_test.setup_managed_buffer(buffer_path, { "" }, { view = { display = "tab" } })
local state = require("ark").view("data.frame(id = c(10000:10800, 326L, 789L, rep(44444L, 326), rep(55555L, 789)))", 0)
assert(type(state) == "table", "ArkView did not open")
ark_test.wait_for("ArkView rows", 5000, function()
  local rows = vim.api.nvim_buf_get_lines(state.grid_buf, 0, -1, false)
  return not table.concat(rows, "\n"):find("loading rows", 1, true)
end)

-- Use the actual f mapping and Snacks picker/matcher. Numeric IDs must not
-- match a picker's row index or a value's frequency displayed alongside it.
local origin_win = vim.api.nvim_get_current_win()
local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
vim.api.nvim_feedkeys("f", "xt", false)
local picker
ark_test.wait_for("ArkView value picker", 5000, function()
  picker = snacks.picker.get()[1]
  return picker and picker.opts.title == "ArkView Values: id" and #picker:items() == 805
end)
local failures = {}
local displayed_count = false
for _, item in ipairs(picker:items()) do
  if item.item.label == "44444" then
    local chunks = picker.opts.format(item, picker)
    for _, chunk in ipairs(chunks) do
      displayed_count = displayed_count or chunk[1]:find("44444 (326)", 1, true) ~= nil
    end
  end
end
assert(displayed_count, "value frequencies must remain visible")
for _, query in ipairs({ "326", "789" }) do
  local matched = false
  picker.input:set(query)
  picker:find({
    on_done = function()
      matched = true
    end,
  })
  ark_test.wait_for("numeric value match", 5000, function()
    return matched
  end)
  local found_exact = false
  local pattern = table.concat(vim.split(query, ""), ".*")
  for _, item in ipairs(picker:items()) do
    local label = tostring(item.item.label)
    found_exact = found_exact or label == query
    if not label:find(pattern) then
      failures[#failures + 1] = query .. " matched metadata rather than contents: " .. label
    end
  end
  assert(found_exact, "missing actual numeric ID " .. query)
end
if #failures > 0 then
  picker:close()
  require("ark").view_close()
  error(table.concat(failures, "\n"), 0)
end
for index, item in ipairs(picker:items()) do
  if item.item.label == "789" then
    picker.list:view(index)
    break
  end
end
picker:action("confirm")
ark_test.wait_for("exact ID filter", 5000, function()
  return state.total_rows == 1
    and state.filters[1]
    and state.filters[1].query == "789"
    and state.filters[1].mode == "exact"
end)
assert(vim.api.nvim_get_current_win() == origin_win, "confirming f moved focus from the grid to Columns")
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(origin_win), origin_cursor), "confirming f moved the grid cursor")
require("ark").view_close()
