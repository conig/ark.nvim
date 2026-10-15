local ark_test = require("ark_test")
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local snacks = require("snacks")
snacks.setup({ picker = { enabled = true } })
local ark = require("ark")
local _, client = ark_test.setup_managed_buffer(
  ark_test.run_tmpdir() .. "/values-responsive.R",
  { "" },
  { view = { display = "tab" } }
)

local function cursor_cell(state)
  local cursor = vim.api.nvim_win_get_cursor(state.grid_win)
  for _, span in ipairs(state.column_spans) do
    if span.column_index == state.selected_column then
      return { row = cursor[1], column = state.selected_column, offset = cursor[2] - span.start_col }
    end
  end
end

local function open_values(expr)
  local state = assert(ark.view(expr, 0))
  ark_test.wait_for("rows", 5000, function()
    return not state.page_loading
  end)
  local started = vim.uv.hrtime()
  vim.api.nvim_feedkeys("ff", "xt", false)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  print(string.format("f returned in %.1fms", elapsed))
  assert(elapsed < 250, string.format("f blocked the editor for %.1fms", elapsed))
  local picker
  ark_test.wait_for("value picker", 15000, function()
    picker = snacks.picker.get()[1]
    return picker and #picker:items() > 0
  end)
  assert(#snacks.picker.get() == 1, "repeated f opened duplicate pickers")
  return state, picker
end

-- Adjacent coverage: the filtered capitals subset must retain normal selection.
local _, picker = open_values(
  [=[data.table::as.data.table(maps::world.cities)[capital == 1 | name == "Xianggangdao", .(country = ifelse(name == "Xianggangdao", "Hong Kong", country.etc), pop, long, lat)]]=]
)
assert(#picker:items() > 200, "missing capital countries")
picker:close()
ark.view_close()

-- A high-cardinality column must not freeze Neovim or send an unbounded picker.
local state
state, picker = open_values([[data.table::as.data.table(maps::world.cities)]])
assert(#picker:items() <= 1000, "unbounded value picker")
local fixture_rows = state.total_rows
picker.input:set("", "Xianggangdao")
picker:find()
ark_test.wait_for("server-side value search", 5000, function()
  return #picker:items() == 1 and picker:items()[1].item.label == "Xianggangdao"
end)
local debug = ark_test.request(client, "ark/internal/status", {}, 5000)
local found = false
for _, request in ipairs(debug.sessionBridge.runtime.recentRequests or {}) do
  local details = request.exchange and request.exchange.handler
  if request.operation == "view_values" and details and details.rows == fixture_rows then
    found = true
    assert(details.returned <= 1000 and request.exchange.responseBytes > 0)
  end
end
assert(found, "LSP status lost value-handler timing/count evidence")
local status = ark.status()
assert(
  status.bridge_diagnostics and #(status.bridge_diagnostics.recent_view_values or {}) > 0,
  "normal pings did not retain R encoding diagnostics"
)
assert(
  not vim.inspect(debug.sessionBridge.runtime):find("Xianggangdao", 1, true),
  "diagnostics leaked cell/search contents"
)
local origin_cell = cursor_cell(state)
picker:action("confirm")
ark_test.wait_for("exact city filter", 5000, function()
  return state.total_rows == 1 and state.filters[1] and state.filters[1].mode == "exact"
end)
assert(vim.api.nvim_get_current_win() == state.grid_win, "live value search moved focus to Columns")
-- The row-number gutter shrinks after filtering 43,645 rows down to one;
-- preserve the logical cell, not its old absolute byte column.
assert(vim.deep_equal(cursor_cell(state), origin_cell), "live value search moved to a different cell")
-- A filter invoked from Columns must return there instead of forcing the grid.
vim.api.nvim_set_current_win(state.sidebar_win)
local sidebar_cursor = vim.api.nvim_win_get_cursor(state.sidebar_win)
vim.api.nvim_feedkeys("f", "xt", false)
ark_test.wait_for("sidebar value picker", 5000, function()
  picker = snacks.picker.get()[1]
  return picker and #picker:items() > 0
end)
picker.input:set("", "Xianggangdao")
picker:find()
ark_test.wait_for("sidebar value match", 5000, function()
  return #picker:items() == 1 and picker:items()[1].item.label == "Xianggangdao"
end)
local before_page = state.page_request_generation
picker:action("confirm")
ark_test.wait_for("return from sidebar filter", 5000, function()
  return #snacks.picker.get() == 0 and state.page_request_generation > before_page and not state.page_loading
end)
assert(vim.api.nvim_get_current_win() == state.sidebar_win, "sidebar filter moved focus to the grid")
assert(
  vim.deep_equal(vim.api.nvim_win_get_cursor(state.sidebar_win), sidebar_cursor),
  "sidebar filter moved the cursor"
)
picker:close()
ark.view_close()

-- Closing while values are loading must not wait for R or resurrect a picker.
state = assert(require("ark.view").open({
  expr = "data.table::as.data.table(maps::world.cities)",
  source_bufnr = state.source_bufnr,
  options = ark.options(),
  lsp = require("ark.lsp"),
}))
ark_test.wait_for("rows before close", 5000, function()
  return not state.page_loading
end)
vim.api.nvim_feedkeys("f", "xt", false)
local closed_at = vim.uv.hrtime()
ark.view_close()
assert((vim.uv.hrtime() - closed_at) / 1e6 < 250, "closing waited for the value request")
vim.wait(1000, function()
  return false
end, 20)
assert(#snacks.picker.get() == 0, "closed view resurrected a picker")
