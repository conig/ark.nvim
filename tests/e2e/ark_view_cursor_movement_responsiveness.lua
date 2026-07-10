vim.opt.rtp:prepend(vim.fn.getcwd())

local view = require("ark.view")
local perf = require("perf")

vim.o.columns = 140
vim.o.lines = 40

local schema = {}
local rows = {}
for column_index = 1, 338 do
  schema[column_index] = {
    index = column_index,
    name = string.format("wide_%03d", column_index),
    class = "character",
    type = "character",
  }
end
for row_index = 1, 148 do
  local row = {}
  for column_index = 1, 338 do
    row[column_index] = string.format("r%03d_c%03d", row_index, column_index)
  end
  rows[row_index] = row
end

local function snapshot()
  return {
    session_id = "ark-view-cursor-responsive",
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

local requested_page_columns = nil

local function page(offset, limit, columns)
  local started = vim.uv.hrtime()
  local start_index = math.max(0, tonumber(offset or 0) or 0) + 1
  local page_limit = math.max(0, tonumber(limit or 0) or 0)
  local end_index = page_limit == 0 and #rows or math.min(#rows, start_index + page_limit - 1)
  local page_rows = {}
  local row_numbers = {}
  local projected_columns = vim.islist(columns) and vim.deepcopy(columns) or {}
  requested_page_columns = projected_columns

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

  local result = {
    offset = start_index - 1,
    limit = page_limit,
    columns = projected_columns,
    total_rows = #rows,
    row_numbers = row_numbers,
    rows = page_rows,
  }
  perf.record("arkview.page", (vim.uv.hrtime() - started) / 1000000, {
    test = "ark_view_cursor_movement_responsiveness.lua",
    condition = "warm mocked bridge boundary",
    fixture = "148 rows by 338 columns",
  })
  return result
end

local lsp = {
  view_open = function()
    return snapshot(), nil
  end,
  view_page = function(_opts, _bufnr, _session_id, offset, limit, columns)
    return page(offset, limit, columns), nil
  end,
  view_close = function()
    return { closed = true }, nil
  end,
}

local function header_column(lines, name)
  local header = lines[1] or ""
  local start_col = header:find(name, 1, true)
  if not start_col then
    error("expected header to contain column " .. name .. ", got " .. vim.inspect(lines), 0)
  end
  return start_col - 1
end

local function max_line_display_width(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

local function ark_view_extmark_count(buf)
  local namespace = vim.api.nvim_get_namespaces()["ark-view"]
  if not namespace then
    error("expected ark-view highlight namespace", 0)
  end
  return #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
end

local function sticky_header_float(anchor_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative == "win" and config.win == anchor_win then
      local buf = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = lines[1] or ""
      if text:find("#", 1, true) and text:find("|", 1, true) then
        return {
          win = win,
          buf = buf,
          lines = lines,
          config = config,
          view = vim.api.nvim_win_call(win, function()
            return vim.fn.winsaveview()
          end),
        }
      end
    end
  end
  return nil
end

local function move_cursor(win, row, col)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = vim.api.nvim_win_get_buf(win),
    modeline = false,
  })
end

local ok, err = pcall(function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_cursor_movement_responsiveness.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "wide_table" })

  local open_started = vim.uv.hrtime()
  local state, open_err = view.open({
    lsp = lsp,
    options = {},
    source_bufnr = source_buf,
    expr = "wide_table",
    page_limit = 0,
    notify = function() end,
  })
  perf.record("arkview.open", (vim.uv.hrtime() - open_started) / 1000000, {
    test = "ark_view_cursor_movement_responsiveness.lua",
    condition = "cold view in headless Neovim",
    fixture = "148 rows by 338 columns",
  })
  if not state then
    error("expected ArkView to open: " .. tostring(open_err), 0)
  end
  if not vim.islist(requested_page_columns) or #requested_page_columns == 0 or #requested_page_columns >= #schema then
    error(
      "expected 148x338 ArkView first page request to project visible columns, got "
        .. vim.inspect(requested_page_columns),
      0
    )
  end
  if not vim.tbl_contains(requested_page_columns, 12) then
    error("expected projected first page to include wide_012, got " .. vim.inspect(requested_page_columns), 0)
  end

  local grid_win = state.grid_win
  local grid_buf = state.grid_buf
  local grid_lines = vim.api.nvim_buf_get_lines(grid_buf, 0, -1, false)
  local grid_width = vim.api.nvim_win_get_width(grid_win)
  local line_width_budget = math.max(512, grid_width * 5)
  local rendered_width = max_line_display_width(grid_lines)
  if rendered_width > line_width_budget then
    error(
      string.format(
        "expected 148x338 ArkView render to stay near the visible viewport, got max line width %d with budget %d",
        rendered_width,
        line_width_budget
      ),
      0
    )
  end

  local extmark_count = ark_view_extmark_count(grid_buf)
  if extmark_count > 6000 then
    error(
      string.format("expected bounded wide-table highlight count, got %d extmarks", extmark_count),
      0
    )
  end

  local wide_col = header_column(grid_lines, "wide_012")

  move_cursor(grid_win, 40, wide_col)
  vim.cmd("normal! zt")
  vim.api.nvim_exec_autocmds("WinScrolled", {
    pattern = tostring(grid_win),
    modeline = false,
  })

  local sticky = sticky_header_float(grid_win)
  if not sticky then
    error("expected a sticky ArkView header after scrolling", 0)
  end

  local selected_row_before = state.selected_row
  local original_buf_set_lines = vim.api.nvim_buf_set_lines
  local original_win_set_config = vim.api.nvim_win_set_config
  local sticky_buf_repaints = 0
  local sticky_win_reconfigs = 0
  local samples = {}

  vim.api.nvim_buf_set_lines = function(buf, start, stop, strict, replacement)
    if buf == sticky.buf then
      sticky_buf_repaints = sticky_buf_repaints + 1
    end
    return original_buf_set_lines(buf, start, stop, strict, replacement)
  end
  vim.api.nvim_win_set_config = function(win, config)
    if win == sticky.win then
      sticky_win_reconfigs = sticky_win_reconfigs + 1
    end
    return original_win_set_config(win, config)
  end

  local move_count = 80
  for line = 41, 40 + move_count do
    local started = vim.uv.hrtime()
    move_cursor(grid_win, line, wide_col)
    samples[#samples + 1] = (vim.uv.hrtime() - started) / 1000000
  end

  for _, value in ipairs(samples) do
    perf.record("arkview.cursor", value, {
      test = "ark_view_cursor_movement_responsiveness.lua",
      condition = "warm same-column cursor movement",
      fixture = "148 rows by 338 columns",
    })
  end

  vim.api.nvim_buf_set_lines = original_buf_set_lines
  vim.api.nvim_win_set_config = original_win_set_config

  if state.selected_row ~= selected_row_before + move_count then
    error(
      "expected row selection to follow cursor movement, got before="
        .. tostring(selected_row_before)
        .. " after="
        .. tostring(state.selected_row),
      0
    )
  end

  if sticky_buf_repaints ~= 0 or sticky_win_reconfigs ~= 0 then
    error(
      "expected same-column cursor movement to leave sticky header untouched, got repaints="
        .. tostring(sticky_buf_repaints)
        .. " reconfigs="
        .. tostring(sticky_win_reconfigs),
      0
    )
  end

  table.sort(samples)
  local p95_index = math.max(1, math.min(#samples, math.ceil(#samples * 0.95)))
  local p95_ms = samples[p95_index]
  local max_ms = samples[#samples]
  if p95_ms > 8 or max_ms > 16 then
    error(
      string.format(
        "expected 148x338 ArkView cursor movement to stay responsive, got p95=%.3fms max=%.3fms n=%d",
        p95_ms,
        max_ms,
        #samples
      ),
      0
    )
  end
end)

if not ok then
  vim.notify(err, vim.log.levels.ERROR)
  error(err, 0)
end

vim.g.ark_view_cursor_movement_responsiveness = "ok"
