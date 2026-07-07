vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local view = require("ark.view")

vim.o.columns = 140
vim.o.lines = 40

local schema = {}
local rows = {}
for column_index = 1, 120 do
  schema[column_index] = {
    index = column_index,
    name = string.format("col_%03d", column_index),
    class = "character",
    type = "character",
  }
end
for row_index = 1, 40 do
  local row = {}
  for column_index = 1, #schema do
    row[column_index] = string.format("r%03d_c%03d", row_index, column_index)
  end
  rows[row_index] = row
end

local function snapshot()
  return {
    session_id = "ark-view-async-open",
    title = "wide_table",
    total_rows = #rows,
    total_columns = #schema,
    schema = vim.deepcopy(schema),
    filters = {},
    sort = {
      column_index = 0,
      direction = "",
    },
  }
end

local sync_page_calls = 0
local async_page_calls = 0
local requested_async_columns = nil
local async_page_completed = false

local function page(offset, limit, columns)
  local start_index = math.max(0, tonumber(offset or 0) or 0) + 1
  local page_limit = math.max(0, tonumber(limit or 0) or 0)
  local end_index = page_limit == 0 and #rows or math.min(#rows, start_index + page_limit - 1)
  local projected_columns = vim.islist(columns) and vim.deepcopy(columns) or {}
  local page_rows = {}
  local row_numbers = {}

  for index = start_index, end_index do
    if #projected_columns > 0 then
      local row = {}
      for _, column_index in ipairs(projected_columns) do
        row[tostring(column_index)] = rows[index][column_index]
      end
      page_rows[#page_rows + 1] = row
    else
      page_rows[#page_rows + 1] = vim.deepcopy(rows[index])
    end
    row_numbers[#row_numbers + 1] = index
  end

  return {
    offset = start_index - 1,
    limit = page_limit,
    columns = projected_columns,
    total_rows = #rows,
    row_numbers = row_numbers,
    rows = page_rows,
  }
end

local lsp = {
  view_open = function()
    return snapshot(), nil
  end,
  view_page = function(_opts, _bufnr, _session_id, offset, limit, columns)
    sync_page_calls = sync_page_calls + 1
    vim.wait(250, function()
      return false
    end, 10, false)
    return page(offset, limit, columns), nil
  end,
  view_page_async = function(_opts, _bufnr, _session_id, offset, limit, columns, callback)
    async_page_calls = async_page_calls + 1
    requested_async_columns = vim.deepcopy(columns or {})
    vim.defer_fn(function()
      async_page_completed = true
      callback(page(offset, limit, columns), nil)
    end, 120)
    return async_page_calls, nil
  end,
  view_close = function()
    return { closed = true }, nil
  end,
}

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local ok, err = pcall(function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_async_open.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "wide_table" })

  -- Regression: opening ArkView must materialize the UI from schema immediately
  -- and let the first potentially expensive page request complete later.
  local started = vim.uv.hrtime()
  local state, open_err = view.open({
    lsp = lsp,
    options = {},
    source_bufnr = source_buf,
    expr = "wide_table",
    page_limit = 0,
    notify = function() end,
  })
  local open_ms = (vim.uv.hrtime() - started) / 1000000

  if not state then
    ark_test.fail("expected ArkView to open: " .. tostring(open_err))
  end
  if open_ms > 100 then
    ark_test.fail(string.format("expected nonblocking ArkView open under 100ms, got %.1fms", open_ms))
  end
  if sync_page_calls ~= 0 then
    ark_test.fail("expected ArkView open to avoid synchronous view_page, got " .. tostring(sync_page_calls))
  end
  if async_page_calls ~= 1 then
    ark_test.fail("expected ArkView open to request one async page, got " .. tostring(async_page_calls))
  end
  if not vim.api.nvim_win_is_valid(state.grid_win) then
    ark_test.fail("expected ArkView grid window to exist immediately")
  end
  if not buffer_text(state.grid_buf):find("loading rows", 1, true) then
    ark_test.fail("expected initial grid to show a loading placeholder before async rows arrive")
  end
  if not vim.islist(requested_async_columns) or #requested_async_columns == 0 or #requested_async_columns >= #schema then
    ark_test.fail("expected async first page to request projected visible columns, got " .. vim.inspect(requested_async_columns))
  end

  ark_test.wait_for("async ArkView first page", 1000, function()
    return async_page_completed and buffer_text(state.grid_buf):find("r001_c001", 1, true) ~= nil
  end)

  local grid_text = buffer_text(state.grid_buf)
  if grid_text:find("loading rows", 1, true) then
    ark_test.fail("expected loading placeholder to be replaced by data rows")
  end
  if not grid_text:find("r001_c001", 1, true) then
    ark_test.fail("expected first loaded row in ArkView grid, got " .. grid_text)
  end
  if not grid_text:find("col_001", 1, true) then
    ark_test.fail("expected headers to render before and after async page load, got " .. grid_text)
  end
end)

pcall(view.close)
if not ok then
  error(err, 0)
end
