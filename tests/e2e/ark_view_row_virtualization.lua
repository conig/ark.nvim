vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local view = require("ark.view")

vim.o.columns = 132
vim.o.lines = 38

local total_rows = 10000
local schema = {}
for column_index = 1, 36 do
  schema[column_index] = {
    index = column_index,
    name = string.format("field_%02d", column_index),
    class = "character",
    type = "character",
  }
end

local requests = {}
local cell_requests = {}

local function snapshot()
  return {
    session_id = "ark-view-row-virtualization",
    title = "tall_table",
    total_rows = total_rows,
    total_columns = #schema,
    schema = vim.deepcopy(schema),
    filters = {},
    sort = {
      column_index = 0,
      direction = "",
    },
  }
end

local function cell_value(row_index, column_index)
  return string.format("r%05d_c%02d", row_index, column_index)
end

local function page(offset, limit, columns)
  local start_index = math.max(0, tonumber(offset or 0) or 0) + 1
  local page_limit = math.max(0, tonumber(limit or 0) or 0)
  local end_index = page_limit == 0 and total_rows or math.min(total_rows, start_index + page_limit - 1)
  local projected_columns = vim.islist(columns) and vim.deepcopy(columns) or {}
  local page_rows = {}
  local row_numbers = {}

  for row_index = start_index, end_index do
    if #projected_columns > 0 then
      local row = {}
      for _, column_index in ipairs(projected_columns) do
        row[tostring(column_index)] = cell_value(row_index, column_index)
      end
      page_rows[#page_rows + 1] = row
    else
      local row = {}
      for column_index = 1, #schema do
        row[column_index] = cell_value(row_index, column_index)
      end
      page_rows[#page_rows + 1] = row
    end
    row_numbers[#row_numbers + 1] = row_index
  end

  return {
    offset = start_index - 1,
    limit = page_limit,
    columns = projected_columns,
    total_rows = total_rows,
    row_numbers = row_numbers,
    rows = page_rows,
  }
end

local lsp = {
  view_open = function()
    return snapshot(), nil
  end,
  view_page_async = function(_opts, _bufnr, _session_id, offset, limit, columns, callback)
    requests[#requests + 1] = {
      offset = tonumber(offset or 0) or 0,
      limit = tonumber(limit or 0) or 0,
      columns = vim.deepcopy(columns or {}),
    }
    vim.defer_fn(function()
      callback(page(offset, limit, columns), nil)
    end, 20)
    return #requests, nil
  end,
  view_cell = function(_opts, _bufnr, _session_id, row_index, column_index)
    cell_requests[#cell_requests + 1] = {
      row_index = row_index,
      column_index = column_index,
    }
    return {
      text = cell_value(row_index, column_index),
    }, nil
  end,
  view_close = function()
    return { closed = true }, nil
  end,
}

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function press(keys)
  local translated = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(translated, "xt", false)
  vim.cmd("redraw")
end

local function wait_for_grid_text(state, label, text)
  ark_test.wait_for(label, 1000, function()
    return buffer_text(state.grid_buf):find(text, 1, true) ~= nil
  end)
end

local ok, err = pcall(function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_row_virtualization.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "tall_table" })

  -- Regression: default ArkView must preserve access to all rows without asking
  -- the bridge to format every row of a tall object for the first paint.
  local state, open_err = view.open({
    lsp = lsp,
    options = {},
    source_bufnr = source_buf,
    expr = "tall_table",
    page_limit = 0,
    notify = function() end,
  })
  if not state then
    ark_test.fail("expected ArkView to open: " .. tostring(open_err))
  end
  if #requests ~= 1 then
    ark_test.fail("expected one initial page request, got " .. vim.inspect(requests))
  end
  if requests[1].limit == 0 or requests[1].limit > 400 then
    ark_test.fail("expected bounded initial virtual row request, got " .. vim.inspect(requests[1]))
  end

  wait_for_grid_text(state, "initial virtual row window", "r00001_c01")
  local line_count = vim.api.nvim_buf_line_count(state.grid_buf)
  if line_count > requests[1].limit + 4 then
    ark_test.fail(
      "expected rendered buffer to stay bounded by the virtual row window, got line_count="
        .. tostring(line_count)
        .. " request="
        .. vim.inspect(requests[1])
    )
  end
  if not vim.wo[state.grid_win].winbar:find("Rows 1%-" .. tostring(requests[1].limit) .. "/" .. tostring(total_rows)) then
    ark_test.fail("expected winbar to show first virtual row window, got " .. vim.inspect(vim.wo[state.grid_win].winbar))
  end

  vim.api.nvim_set_current_win(state.grid_win)
  press(tostring(requests[1].limit) .. "G")
  if tonumber(state.selected_row or 0) ~= requests[1].limit then
    ark_test.fail("expected counted G to select the last row in the initial virtual window")
  end
  local before_boundary_motion_requests = #requests
  press("j")
  ark_test.wait_for("row motion across virtual boundary", 1000, function()
    return #requests > before_boundary_motion_requests and requests[#requests].offset > 0
  end)
  wait_for_grid_text(state, "row motion virtual boundary data", cell_value(requests[1].limit + 1, 1))

  press("<CR>")
  ark_test.wait_for("row motion absolute cell request", 1000, function()
    return cell_requests[#cell_requests] and cell_requests[#cell_requests].row_index == requests[1].limit + 1
  end)

  press("gg")
  ark_test.wait_for("restore first virtual row window after row motion", 1000, function()
    return requests[#requests] and requests[#requests].offset == 0
  end)
  wait_for_grid_text(state, "first virtual row window restored after row motion", cell_value(1, 1))

  local second_offset = requests[1].limit
  local before_next_page_requests = #requests
  press("]p")
  ark_test.wait_for("next virtual row window request", 1000, function()
    return #requests > before_next_page_requests and requests[#requests].offset == second_offset
  end)
  wait_for_grid_text(state, "next virtual row window data", cell_value(second_offset + 1, 1))

  press("G")
  ark_test.wait_for("last virtual row window request", 1000, function()
    return requests[#requests] and requests[#requests].offset >= total_rows - requests[1].limit
  end)
  wait_for_grid_text(state, "last virtual row window data", cell_value(total_rows, 1))

  press("<CR>")
  ark_test.wait_for("last row cell request", 1000, function()
    return cell_requests[#cell_requests] and cell_requests[#cell_requests].row_index == total_rows
  end)

  press("gg")
  ark_test.wait_for("first virtual row window request", 1000, function()
    return requests[#requests] and requests[#requests].offset == 0
  end)
  wait_for_grid_text(state, "first virtual row window restored", cell_value(1, 1))
end)

pcall(view.close)
if not ok then
  error(err, 0)
end
