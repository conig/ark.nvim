local M = {}

local states = {}
local highlight_namespace = vim.api.nvim_create_namespace("ark-view")

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "ArkViewHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "ArkViewSummary", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ArkViewSeparator", { link = "NonText", default = true })
  vim.api.nvim_set_hl(0, "ArkViewRowNumber", { link = "LineNr", default = true })
  vim.api.nvim_set_hl(0, "ArkViewProfileTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "ArkViewProfileSection", { link = "Statement", default = true })
  vim.api.nvim_set_hl(0, "ArkViewProfileLabel", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "ArkViewProfileBar", { link = "String", default = true })
  vim.api.nvim_set_hl(0, "ArkViewProfileMuted", { link = "Comment", default = true })
end

local function valid_tab(tabpage)
  return type(tabpage) == "number" and vim.api.nvim_tabpage_is_valid(tabpage)
end

local function valid_win(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

local function current_state()
  return states[vim.api.nvim_get_current_tabpage()]
end

local function notify(state, message, level)
  local fn = state and state.notify
  if type(fn) == "function" then
    fn(message, level)
    return
  end
  vim.notify(message, level or vim.log.levels.INFO, { title = "ark.nvim" })
end

local function with_tab(tabpage, fn)
  if not valid_tab(tabpage) then
    return nil
  end

  local prev_tab = vim.api.nvim_get_current_tabpage()
  local prev_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_tabpage(tabpage)
  local ok, result = pcall(fn)
  if valid_tab(prev_tab) then
    vim.api.nvim_set_current_tabpage(prev_tab)
    if valid_win(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
  end
  if not ok then
    error(result)
  end
  return result
end

local function new_scratch_buffer(filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  if type(filetype) == "string" and filetype ~= "" then
    vim.bo[buf].filetype = filetype
  end
  return buf
end

local function set_buffer_lines(buf, lines)
  if not valid_buf(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

local function display_width(text)
  return vim.fn.strdisplaywidth(tostring(text or ""))
end

local function clip_text(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if display_width(text) <= width then
    return text
  end
  if width == 1 then
    return text:sub(1, 1)
  end
  return text:sub(1, width - 1) .. ">"
end

local function pad_text(text, width)
  text = clip_text(text, width)
  local padding = width - display_width(text)
  if padding <= 0 then
    return text
  end
  return text .. string.rep(" ", padding)
end

local function statusline_escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

local function set_highlight(buf, group, row, start_col, end_col, priority)
  if start_col >= end_col then
    return
  end

  vim.api.nvim_buf_set_extmark(buf, highlight_namespace, row, start_col, {
    end_row = row,
    end_col = end_col,
    hl_group = group,
    priority = priority or 100,
  })
end

local function highlight_pipe_separators(buf, row, line)
  local search_start = 1
  while true do
    local pipe_col = line:find("|", search_start, true)
    if not pipe_col then
      return
    end

    set_highlight(buf, "ArkViewSeparator", row, pipe_col - 1, pipe_col, 120)
    search_start = pipe_col + 1
  end
end

local function apply_grid_highlights(state, lines, row_width)
  if not valid_buf(state.grid_buf) then
    return
  end

  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(state.grid_buf, highlight_namespace, 0, -1)

  for index, line in ipairs(lines) do
    local row = index - 1
    if row == 0 then
      set_highlight(state.grid_buf, "ArkViewHeader", row, 0, #line, 100)
      set_highlight(state.grid_buf, "ArkViewRowNumber", row, 0, math.min(row_width, #line), 110)
    elseif line ~= "(no rows)" then
      set_highlight(state.grid_buf, "ArkViewRowNumber", row, 0, math.min(row_width, #line), 110)
    end
    highlight_pipe_separators(state.grid_buf, row, line)
  end
end

local function apply_sidebar_highlights(state, lines)
  if not valid_buf(state.sidebar_buf) then
    return
  end

  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(state.sidebar_buf, highlight_namespace, 0, -1)
  if lines[1] then
    set_highlight(state.sidebar_buf, "ArkViewHeader", 0, 0, #lines[1], 100)
  end
end

local function apply_profile_highlights(buf, lines)
  if not valid_buf(buf) then
    return
  end

  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(buf, highlight_namespace, 0, -1)

  for index, line in ipairs(lines) do
    local row = index - 1
    if row == 0 then
      set_highlight(buf, "ArkViewProfileTitle", row, 0, #line, 130)
    elseif line:match("^#%s+") then
      set_highlight(buf, "ArkViewProfileSection", row, 0, #line, 130)
    elseif line:match("^[%w%s]+:$") then
      set_highlight(buf, "ArkViewProfileSection", row, 0, #line, 130)
    elseif line:match("^%s+no ") then
      set_highlight(buf, "ArkViewProfileMuted", row, 0, #line, 110)
    else
      local pipe_col = line:find("|", 1, true)
      local colon_col = line:find(":", 1, true)
      if pipe_col then
        set_highlight(buf, "ArkViewSeparator", row, pipe_col - 1, pipe_col, 130)
        local bar_start = line:find("#", pipe_col + 1, true)
        if bar_start then
          local bar_end = bar_start
          while line:sub(bar_end + 1, bar_end + 1) == "#" do
            bar_end = bar_end + 1
          end
          set_highlight(buf, "ArkViewProfileBar", row, bar_start - 1, bar_end, 140)
        end
      elseif colon_col then
        local label_start = line:find("%S") or 1
        set_highlight(buf, "ArkViewProfileLabel", row, label_start - 1, colon_col, 120)
      end
    end
  end
end

local function schema_by_index(state, column_index)
  for _, item in ipairs(state.schema or {}) do
    if tonumber(item.index) == tonumber(column_index) then
      return item
    end
  end
  return nil
end

local function column_label(state, column_index)
  local item = schema_by_index(state, column_index)
  return (item and item.name) or ("#" .. tostring(column_index))
end

local function active_filter_count(state)
  local count = 0
  local first_column = nil
  for _, item in ipairs(state.filters or {}) do
    if tostring(item.query or "") ~= "" then
      count = count + 1
      if not first_column then
        first_column = tonumber(item.column_index)
      end
    end
  end
  return count, first_column
end

local function row_summary(state)
  local total = tonumber(state.total_rows or 0) or 0
  if total <= 0 then
    return "Rows 0"
  end

  local rows = state.rows or {}
  if #rows == 0 then
    return string.format("Rows 0/%d", total)
  end

  local offset = tonumber(state.page_offset or 0) or 0
  local first = math.min(total, offset + 1)
  local last = math.min(total, offset + #rows)
  return string.format("Rows %d-%d/%d", first, last, total)
end

local function filter_summary(state)
  local count, first_column = active_filter_count(state)
  if count == 0 then
    return "Filters 0"
  end
  if count == 1 then
    return "Filter " .. column_label(state, first_column)
  end
  return "Filters " .. tostring(count)
end

local function sort_summary(state)
  local sort = state.sort or {}
  local direction = tostring(sort.direction or "")
  local column_index = tonumber(sort.column_index)
  if direction == "" or not column_index or column_index <= 0 then
    return "Sort none"
  end
  return "Sort " .. column_label(state, column_index) .. " " .. direction
end

local function update_grid_summary(state)
  if not valid_win(state.grid_win) then
    return
  end

  ensure_highlights()
  local title = state.title or state.expr or "ArkView"
  local parts = {
    statusline_escape(title),
    statusline_escape(row_summary(state)),
    statusline_escape(string.format("Columns %d", tonumber(state.total_columns or 0) or 0)),
    statusline_escape(filter_summary(state)),
    statusline_escape(sort_summary(state)),
  }
  local separator = "%#ArkViewSeparator# | %#ArkViewSummary#"
  pcall(function()
    vim.wo[state.grid_win].winbar = "%#ArkViewSummary#" .. table.concat(parts, separator) .. "%*"
  end)
end

local function current_filter(state, column_index)
  for _, item in ipairs(state.filters or {}) do
    if tonumber(item.column_index) == tonumber(column_index) then
      return item.query or ""
    end
  end
  return ""
end

local function current_sort_direction(state, column_index)
  local sort = state.sort or {}
  if tonumber(sort.column_index) == tonumber(column_index) then
    return sort.direction or ""
  end
  return ""
end

local function current_row_offset(state)
  return tonumber(state.page_offset or 0) or 0
end

local function current_row_index(state)
  if not valid_win(state.grid_win) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.grid_win)[1]
  if line < 2 then
    return nil
  end
  local data_row = line - 1
  if data_row < 1 or data_row > #(state.rows or {}) then
    return nil
  end
  return data_row
end

local function absolute_row_index(state)
  local page_row = current_row_index(state)
  if not page_row then
    return nil
  end
  return current_row_offset(state) + page_row
end

local function selected_column_from_grid(state)
  if not valid_win(state.grid_win) then
    return state.selected_column
  end
  local cursor = vim.api.nvim_win_get_cursor(state.grid_win)
  local col = cursor[2]
  for _, span in ipairs(state.column_spans or {}) do
    if col >= span.start_col and col <= span.end_col then
      return span.column_index
    end
  end
  return state.selected_column
end

local function update_sidebar_cursor(state)
  if not valid_win(state.sidebar_win) then
    return
  end
  local line = 3
  for index, item in ipairs(state.schema or {}) do
    if tonumber(item.index) == tonumber(state.selected_column) then
      line = index + 2
      break
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(state.sidebar_win)
  if cursor[1] ~= line or cursor[2] ~= 0 then
    vim.api.nvim_win_set_cursor(state.sidebar_win, { line, 0 })
  end
end

local function render_sidebar(state)
  local lines = {
    string.format("Columns %d", tonumber(state.total_columns or 0) or 0),
    "",
  }

  for _, item in ipairs(state.schema or {}) do
    local index = tonumber(item.index) or 0
    local prefix = (index == tonumber(state.selected_column)) and ">" or " "
    local sort_direction = current_sort_direction(state, index)
    local filter_text = current_filter(state, index)
    local badges = {}
    if sort_direction == "asc" then
      badges[#badges + 1] = "asc"
    elseif sort_direction == "desc" then
      badges[#badges + 1] = "desc"
    end
    if filter_text ~= "" then
      badges[#badges + 1] = "filter"
    end
    local suffix = (#badges > 0) and (" [" .. table.concat(badges, ",") .. "]") or ""
    lines[#lines + 1] = string.format("%s %2d %-18s %s%s", prefix, index, item.name or "", item.class or item.type or "", suffix)
  end

  set_buffer_lines(state.sidebar_buf, lines)
  apply_sidebar_highlights(state, lines)
  update_sidebar_cursor(state)
end

local function render_details(state, title, text)
  local lines = { title or "Details", "" }
  if type(text) == "string" and text ~= "" then
    vim.list_extend(lines, vim.split(text, "\n", { plain = true, trimempty = false }))
  else
    lines[#lines + 1] = "No details."
  end

  set_buffer_lines(state.details_buf, lines)
end

local function close_float_window(state)
  if not state then
    return
  end

  local return_win = state.float_return_win
  if valid_win(state.float_win) then
    pcall(vim.api.nvim_win_close, state.float_win, true)
  end
  if valid_buf(state.float_buf) then
    pcall(vim.api.nvim_buf_delete, state.float_buf, { force = true })
  end

  state.float_win = nil
  state.float_buf = nil
  state.float_return_win = nil

  if valid_win(return_win) then
    pcall(vim.api.nvim_set_current_win, return_win)
  elseif valid_win(state.grid_win) then
    pcall(vim.api.nvim_set_current_win, state.grid_win)
  end
end

local function open_float_window(state, title, lines, opts)
  if not state or not valid_tab(state.tabpage) then
    return nil, nil
  end

  close_float_window(state)

  if vim.api.nvim_get_current_tabpage() ~= state.tabpage then
    vim.api.nvim_set_current_tabpage(state.tabpage)
  end

  opts = opts or {}
  local return_win = vim.api.nvim_get_current_win()
  local min_width = tonumber(opts.min_width or 52) or 52
  local width_fraction = tonumber(opts.width_fraction or 0.58) or 0.58
  local width = math.min(math.max(min_width, math.floor(vim.o.columns * width_fraction)), math.max(20, vim.o.columns - 6))
  local min_height = tonumber(opts.min_height or 8) or 8
  local height = math.min(math.max(min_height, #lines), math.max(4, vim.o.lines - 8))
  local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local buf = new_scratch_buffer(opts.filetype or "text")

  set_buffer_lines(buf, lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "single",
    title = " " .. tostring(title or "ArkView") .. " ",
    title_pos = "center",
  })

  vim.wo[win].wrap = opts.wrap == true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].winbar = ""

  state.float_buf = buf
  state.float_win = win
  state.float_return_win = return_win

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      close_float_window(state)
    end, { buffer = buf, nowait = true, silent = true })
  end

  return win, buf
end

local function show_help_window(state)
  local lines = {
    "Navigation",
    "  <Tab>  toggle grid/columns focus",
    "  <CR>   inspect current grid cell or jump from columns to grid",
    "  ]p     next page",
    "  [p     previous page",
    "",
    "Columns",
    "  S      search columns",
    "  s      toggle sort on selected column",
    "  /      set text filter on selected column",
    "  p      show column profile",
    "",
    "Data",
    "  c      show generated code",
    "  y      copy current cell",
    "  Y      copy visible filtered table as TSV",
    "",
    "View",
    "  r      refresh",
    "  q      close ArkView outside this help",
    "  Esc/q  close this help",
  }

  open_float_window(state, "ArkView Help", lines, {
    min_width = 52,
    width_fraction = 0.58,
  })
end

local function show_profile_window(state, text)
  local lines = { "Column Profile", "" }
  if type(text) == "string" and text ~= "" then
    vim.list_extend(lines, vim.split(text, "\n", { plain = true, trimempty = false }))
  else
    lines[#lines + 1] = "No details."
  end

  local _, buf = open_float_window(state, "Column Profile", lines, {
    min_width = 64,
    min_height = 10,
    width_fraction = 0.66,
  })
  apply_profile_highlights(buf, lines)
end

local function ensure_details_window(state)
  if valid_win(state.details_win) then
    return state.details_win
  end

  local created = with_tab(state.tabpage, function()
    local grid_win = state.grid_win
    if not valid_win(grid_win) then
      grid_win = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(grid_win)
    vim.cmd("botright 12split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, state.details_buf)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    return win
  end)

  state.details_win = created
  return created
end

local function show_details(state, title, text)
  ensure_details_window(state)
  render_details(state, title, text)
end

local function focus_selected_column_in_grid(state)
  if not valid_win(state.grid_win) then
    return
  end

  vim.api.nvim_set_current_win(state.grid_win)
  local row = math.max(1, (state.selected_row or 1) + 1)
  for _, span in ipairs(state.column_spans or {}) do
    if span.column_index == tonumber(state.selected_column) then
      vim.api.nvim_win_set_cursor(state.grid_win, { row, math.max(0, span.start_col - 1) })
      return
    end
  end

  vim.api.nvim_win_set_cursor(state.grid_win, { row, 0 })
end

local function render_grid(state)
  local rows = state.rows or {}
  local widths = {}
  local row_width = math.max(4, display_width(tostring(state.total_rows or 0)))
  for _, item in ipairs(state.schema or {}) do
    local index = tonumber(item.index) or 0
    widths[index] = math.max(8, math.min(24, display_width(item.name or "")))
  end

  for _, row in ipairs(rows) do
    for index, value in ipairs(row) do
      widths[index] = math.max(widths[index] or 8, math.min(24, display_width(value)))
    end
  end

  local header_parts = { pad_text("#", row_width) }
  local column_spans = {}
  local current_col = row_width + 3
  for _, item in ipairs(state.schema or {}) do
    local index = tonumber(item.index) or 0
    local text = pad_text(item.name or ("V" .. tostring(index)), widths[index] or 8)
    header_parts[#header_parts + 1] = text
    column_spans[#column_spans + 1] = {
      column_index = index,
      start_col = current_col,
      end_col = current_col + display_width(text) - 1,
    }
    current_col = current_col + display_width(text) + 3
  end

  local lines = { table.concat(header_parts, " | ") }
  for row_index, row in ipairs(rows) do
    local number = state.row_numbers and state.row_numbers[row_index] or (current_row_offset(state) + row_index)
    local parts = { pad_text(number, row_width) }
    for index, value in ipairs(row) do
      parts[#parts + 1] = pad_text(value, widths[index] or 8)
    end
    lines[#lines + 1] = table.concat(parts, " | ")
  end

  if #lines == 1 then
    lines[#lines + 1] = "(no rows)"
  end

  state.column_spans = column_spans
  set_buffer_lines(state.grid_buf, lines)
  apply_grid_highlights(state, lines, row_width)
  update_grid_summary(state)
  if valid_win(state.grid_win) then
    local target_row = math.min(#lines, math.max(1, (state.selected_row or 1) + 1))
    vim.api.nvim_win_set_cursor(state.grid_win, { target_row, 0 })
  end
end

local function sync_selected_column(state)
  if not state or not valid_tab(state.tabpage) then
    return
  end

  local previous_column = tonumber(state.selected_column)
  local win = vim.api.nvim_get_current_win()
  if win == state.grid_win then
    state.selected_column = selected_column_from_grid(state) or state.selected_column
    local page_row = current_row_index(state)
    if page_row then
      state.selected_row = page_row
    end
  elseif win == state.sidebar_win then
    local line = vim.api.nvim_win_get_cursor(state.sidebar_win)[1]
    local item = (state.schema or {})[line - 2]
    if item then
      state.selected_column = tonumber(item.index) or state.selected_column
    end
  end

  if tonumber(state.selected_column) ~= previous_column then
    render_sidebar(state)
  end
end

local function toggle_grid_sidebar_focus(state)
  if not state then
    return
  end

  sync_selected_column(state)

  if vim.api.nvim_get_current_win() == state.sidebar_win then
    focus_selected_column_in_grid(state)
    return
  end

  if valid_win(state.sidebar_win) then
    vim.api.nvim_set_current_win(state.sidebar_win)
    update_sidebar_cursor(state)
  end
end

local function safe_close_session(state)
  if not state or type(state.session_id) ~= "string" or state.session_id == "" then
    return
  end

  pcall(state.lsp.view_close, state.options, state.source_bufnr, state.session_id)
  state.session_id = nil
end

local function teardown_state(state)
  if not state or state.closing then
    return
  end
  state.closing = true
  close_float_window(state)
  safe_close_session(state)
  states[state.tabpage] = nil
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
end

local function request_or_error(state, title, fn, ...)
  local result, err = fn(state.options, state.source_bufnr, ...)
  if err then
    show_details(state, title, err)
    notify(state, err, vim.log.levels.WARN)
    return nil, err
  end
  return result, nil
end

local function refresh_page(state, offset)
  state.page_offset = math.max(0, tonumber(offset or state.page_offset or 0) or 0)
  local page, err = request_or_error(state, "ArkView Error", state.lsp.view_page, state.session_id, state.page_offset, state.page_limit)
  if not page then
    return nil, err
  end

  state.rows = page.rows or {}
  state.row_numbers = page.row_numbers or {}
  state.total_rows = tonumber(page.total_rows) or tonumber(state.total_rows) or 0
  if state.selected_row == nil then
    state.selected_row = 1
  end
  state.selected_row = math.max(1, math.min(state.selected_row, math.max(#state.rows, 1)))
  render_grid(state)
  render_sidebar(state)
  return page
end

local function refresh_state(state, preserve_offset)
  local info, err = request_or_error(state, "ArkView Error", state.lsp.view_state, state.session_id)
  if not info then
    return nil, err
  end

  state.title = info.title or state.expr
  state.schema = info.schema or {}
  state.filters = info.filters or {}
  state.sort = info.sort or {}
  state.total_rows = tonumber(info.total_rows) or 0
  state.total_columns = tonumber(info.total_columns) or #(state.schema or {})
  if not preserve_offset then
    state.page_offset = 0
  end
  if state.selected_column == nil and state.schema[1] then
    state.selected_column = tonumber(state.schema[1].index) or 1
  end
  return refresh_page(state, state.page_offset)
end

local function next_sort_direction(direction)
  if direction == "asc" then
    return "desc"
  end
  if direction == "desc" then
    return ""
  end
  return "asc"
end

local function close_tab(state)
  if not state then
    return
  end
  teardown_state(state)
  if valid_tab(state.tabpage) then
    with_tab(state.tabpage, function()
      vim.cmd("tabclose")
    end)
  end
end

local function close_tab_from_owner(state)
  if not state or state.closing then
    return
  end

  close_tab(state)
end

local function open_schema_picker(state)
  local items = {}
  for _, item in ipairs(state.schema or {}) do
    items[#items + 1] = item
  end

  local function choose(item)
    if not item then
      return
    end
    state.selected_column = tonumber(item.index) or state.selected_column
    focus_selected_column_in_grid(state)
    render_sidebar(state)
  end

  local ok, snacks = pcall(require, "snacks")
  if ok and type(snacks) == "table" and type(snacks.picker) == "table" and type(snacks.picker.select) == "function" then
    snacks.picker.select(items, {
      prompt = "ArkView Columns",
      format_item = function(item)
        return string.format("%s (%s)", item.name or "", item.class or item.type or "")
      end,
    }, choose)
    return
  end

  if ok and type(snacks) == "table" and type(snacks.picker) == "table" and type(snacks.picker.pick) == "function" then
    snacks.picker.pick({
      title = "ArkView Columns",
      items = vim.tbl_map(function(item)
        return {
          text = string.format("%s (%s)", item.name or "", item.class or item.type or ""),
          item = item,
        }
      end, items),
      format = "text",
      confirm = function(picker, choice)
        picker:close()
        choose(choice and choice.item or nil)
      end,
    })
    return
  end

  vim.ui.select(items, {
    prompt = "ArkView column",
    format_item = function(item)
      return string.format("%s (%s)", item.name or "", item.class or item.type or "")
    end,
  }, choose)
end

local function setup_keymaps(state)
  local buffers = { state.grid_buf, state.sidebar_buf, state.details_buf }
  local function map(lhs, rhs, target_buffers)
    for _, buf in ipairs(target_buffers or buffers) do
      vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
    end
  end

  map("q", function()
    close_tab(state)
  end)

  map("?", function()
    show_help_window(state)
  end)

  map("r", function()
    local opened, err = request_or_error(state, "ArkView Error", state.lsp.view_open, state.expr)
    if not opened then
      return
    end
    local old_session = state.session_id
    state.session_id = opened.session_id
    state.title = opened.title or state.expr
    state.schema = opened.schema or {}
    state.filters = opened.filters or {}
    state.sort = opened.sort or {}
    state.total_rows = tonumber(opened.total_rows) or 0
    state.total_columns = tonumber(opened.total_columns) or #(state.schema or {})
    state.page_offset = 0
    state.selected_row = 1
    if state.schema[1] then
      state.selected_column = tonumber(state.schema[1].index) or 1
    end
    if old_session and old_session ~= state.session_id then
      pcall(state.lsp.view_close, state.options, state.source_bufnr, old_session)
    end
    refresh_page(state, 0)
  end)

  map("s", function()
    local column_index = tonumber(state.selected_column)
    if not column_index then
      return
    end
    local direction = next_sort_direction(current_sort_direction(state, column_index))
    local updated = request_or_error(state, "ArkView Error", state.lsp.view_sort, state.session_id, column_index, direction)
    if not updated then
      return
    end
    state.sort = updated.sort or {}
    state.filters = updated.filters or state.filters
    state.total_rows = tonumber(updated.total_rows) or state.total_rows
    refresh_page(state, 0)
  end)

  map("/", function()
    local column_index = tonumber(state.selected_column)
    local item = schema_by_index(state, column_index)
    if not item then
      return
    end
    vim.ui.input({
      prompt = "Filter " .. (item.name or "column") .. ": ",
      default = current_filter(state, column_index),
    }, function(input)
      if input == nil then
        return
      end
      local updated = request_or_error(state, "ArkView Error", state.lsp.view_filter, state.session_id, column_index, input)
      if not updated then
        return
      end
      state.sort = updated.sort or state.sort
      state.filters = updated.filters or {}
      state.total_rows = tonumber(updated.total_rows) or state.total_rows
      refresh_page(state, 0)
    end)
  end)

  map("S", function()
    open_schema_picker(state)
  end)

  map("<Tab>", function()
    toggle_grid_sidebar_focus(state)
  end)

  map("p", function()
    local column_index = tonumber(state.selected_column)
    if not column_index then
      return
    end
    local profile = request_or_error(state, "ArkView Error", state.lsp.view_profile, state.session_id, column_index)
    if not profile then
      return
    end
    show_profile_window(state, profile.text or "")
  end)

  map("c", function()
    local code = request_or_error(state, "ArkView Error", state.lsp.view_code, state.session_id)
    if not code then
      return
    end
    vim.fn.setreg('"', code.code or "")
    show_details(state, "Generated Code", code.code or "")
  end)

  map("y", function()
    local row_index = absolute_row_index(state)
    local column_index = tonumber(state.selected_column)
    if not row_index or not column_index then
      return
    end
    local cell = request_or_error(state, "ArkView Error", state.lsp.view_cell, state.session_id, row_index, column_index)
    if not cell then
      return
    end
    vim.fn.setreg('"', cell.text or "")
    show_details(state, "Cell", cell.text or "")
  end)

  map("Y", function()
    local exported = request_or_error(state, "ArkView Error", state.lsp.view_export, state.session_id, "tsv")
    if not exported then
      return
    end
    vim.fn.setreg('"', exported.text or "")
    show_details(state, "Exported Table", exported.text or "")
  end)

  map("<CR>", function()
    local row_index = absolute_row_index(state)
    local column_index = tonumber(state.selected_column)
    if not row_index or not column_index then
      return
    end
    local cell = request_or_error(state, "ArkView Error", state.lsp.view_cell, state.session_id, row_index, column_index)
    if not cell then
      return
    end
    show_details(state, "Cell", cell.text or "")
  end, { state.grid_buf, state.details_buf })

  map("<CR>", function()
    focus_selected_column_in_grid(state)
    render_sidebar(state)
  end, { state.sidebar_buf })

  map("]p", function()
    if current_row_offset(state) + (state.page_limit or 200) >= tonumber(state.total_rows or 0) then
      return
    end
    refresh_page(state, current_row_offset(state) + (state.page_limit or 200))
  end)

  map("[p", function()
    refresh_page(state, math.max(0, current_row_offset(state) - (state.page_limit or 200)))
  end)
end

function M.open(opts)
  opts = opts or {}
  local opened, err = opts.lsp.view_open(opts.options, opts.source_bufnr, opts.expr)
  if err then
    return nil, err
  end

  local page, page_err = opts.lsp.view_page(opts.options, opts.source_bufnr, opened.session_id, 0, opts.page_limit or 200)
  if page_err then
    pcall(opts.lsp.view_close, opts.options, opts.source_bufnr, opened.session_id)
    return nil, page_err
  end

  local source_tab = vim.api.nvim_get_current_tabpage()
  local grid_buf = new_scratch_buffer("")
  local sidebar_buf = new_scratch_buffer("")
  local details_buf = new_scratch_buffer("markdown")

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local grid_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(grid_win, grid_buf)
  vim.wo[grid_win].wrap = false
  vim.wo[grid_win].number = false
  vim.wo[grid_win].relativenumber = false
  vim.wo[grid_win].cursorline = true
  vim.wo[grid_win].cursorlineopt = "line"

  vim.cmd("rightbelow 34vsplit")
  local sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sidebar_win, sidebar_buf)
  vim.wo[sidebar_win].wrap = false
  vim.wo[sidebar_win].number = false
  vim.wo[sidebar_win].relativenumber = false
  vim.wo[sidebar_win].cursorline = true
  vim.wo[sidebar_win].cursorlineopt = "line"
  vim.wo[sidebar_win].winfixwidth = true

  vim.api.nvim_set_current_win(grid_win)

  local state = {
    tabpage = tabpage,
    source_tab = source_tab,
    source_bufnr = opts.source_bufnr,
    expr = opts.expr,
    title = opened.title or opts.expr,
    session_id = opened.session_id,
    schema = opened.schema or {},
    filters = opened.filters or {},
    sort = opened.sort or {},
    total_rows = tonumber(opened.total_rows) or tonumber(page.total_rows) or 0,
    total_columns = tonumber(opened.total_columns) or #(opened.schema or {}),
    rows = page.rows or {},
    row_numbers = page.row_numbers or {},
    page_offset = tonumber(page.offset or 0) or 0,
    page_limit = tonumber(page.limit or opts.page_limit or 200) or 200,
    selected_column = opened.schema and opened.schema[1] and tonumber(opened.schema[1].index) or 1,
    selected_row = 1,
    grid_buf = grid_buf,
    sidebar_buf = sidebar_buf,
    details_buf = details_buf,
    grid_win = grid_win,
    sidebar_win = sidebar_win,
    details_win = nil,
    float_buf = nil,
    float_win = nil,
    float_return_win = nil,
    notify = opts.notify,
    options = opts.options,
    lsp = opts.lsp,
  }

  states[tabpage] = state

  local group = vim.api.nvim_create_augroup("ArkView" .. tostring(tabpage), { clear = true })
  state.augroup = group
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = grid_buf,
    callback = function()
      sync_selected_column(state)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = sidebar_buf,
    callback = function()
      sync_selected_column(state)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = grid_buf,
    callback = function()
      close_tab_from_owner(state)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(grid_win),
    callback = function()
      close_tab_from_owner(state)
    end,
  })

  setup_keymaps(state)
  render_grid(state)
  render_sidebar(state)
  render_details(state, "ArkView", string.format("Rows: %d\nColumns: %d\nExpr: %s", state.total_rows, state.total_columns, state.expr))
  return state
end

function M.refresh()
  local state = current_state()
  if not state then
    return nil, "ArkView is not open in the current tab"
  end
  refresh_state(state, true)
  return state
end

function M.close()
  local state = current_state()
  if not state then
    return nil, "ArkView is not open in the current tab"
  end
  close_tab(state)
  return true
end

return M
