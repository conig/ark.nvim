vim.opt.rtp:prepend(vim.fn.getcwd())

local notifications = {}
local started_lsp = 0
local started_pane = 0
local synced_sessions = 0
local start_bufnrs = {}
local status_bufnrs = {}
local sync_bufnrs = {}
local view_open_bufnrs = {}
local sort_calls = {}
local filter_calls = {}
local profile_calls = {}
local cell_calls = {}
local export_calls = 0
local code_calls = 0
local close_calls = 0
local picker_spec = nil

local original_notify = vim.notify
local original_input = vim.ui.input
local original_select = vim.ui.select

package.loaded["snacks"] = {
  picker = {
    pick = function(spec)
      picker_spec = spec
      if spec.format == nil then
        error("item has no file", 0)
      end
      spec.confirm({
        close = function() end,
      }, (spec.items or {})[2])
    end,
  },
}

vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

local backend = {
  session_id = "view-test-1",
  title = "mtcars",
  schema = {
    { index = 1, name = "mpg", class = "numeric", type = "double" },
    { index = 2, name = "cyl", class = "numeric", type = "double" },
  },
  base_rows = {
    { "21.0", "6" },
    { "22.8", "4" },
    { "18.7", "8" },
  },
  sort = {
    column_index = 0,
    direction = "",
  },
  filters = {},
}

local function copy_sort()
  return {
    column_index = backend.sort.column_index,
    direction = backend.sort.direction,
  }
end

local function copy_filters()
  local filters = {}
  for _, item in ipairs(backend.filters) do
    filters[#filters + 1] = {
      column_index = item.column_index,
      query = item.query,
    }
  end
  return filters
end

local function filtered_rows()
  local rows = vim.deepcopy(backend.base_rows)
  for _, filter in ipairs(backend.filters) do
    if filter.query ~= "" then
      rows = vim.tbl_filter(function(row)
        local value = tostring(row[filter.column_index] or ""):lower()
        return value:find(filter.query:lower(), 1, true) ~= nil
      end, rows)
    end
  end

  if backend.sort.direction ~= "" and backend.sort.column_index > 0 then
    table.sort(rows, function(left, right)
      local lhs = tostring(left[backend.sort.column_index] or "")
      local rhs = tostring(right[backend.sort.column_index] or "")
      if backend.sort.direction == "desc" then
        return lhs > rhs
      end
      return lhs < rhs
    end)
  end

  return rows
end

local function snapshot()
  local rows = filtered_rows()
  return {
    session_id = backend.session_id,
    title = backend.title,
    total_rows = #rows,
    total_columns = #backend.schema,
    schema = vim.deepcopy(backend.schema),
    filters = copy_filters(),
    sort = copy_sort(),
  }
end

local function page(offset, limit)
  local rows = filtered_rows()
  local start_index = math.max(0, tonumber(offset or 0) or 0) + 1
  local end_index = math.min(#rows, start_index + math.max(0, tonumber(limit or 200) or 200) - 1)
  local page_rows = {}
  local row_numbers = {}

  for index = start_index, end_index do
    page_rows[#page_rows + 1] = vim.deepcopy(rows[index])
    row_numbers[#row_numbers + 1] = index
  end

  return {
    offset = start_index - 1,
    limit = limit or 200,
    total_rows = #rows,
    row_numbers = row_numbers,
    rows = page_rows,
  }
end

local function header_column(lines, name)
  local header = lines[1] or ""
  local start_col = header:find(name, 1, true)
  if not start_col then
    error("expected header to contain column " .. name .. ", got " .. vim.inspect(lines), 0)
  end
  return start_col - 1
end

local function assert_sidebar_selected(sidebar_buf, line)
  local lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
  for index = 3, #lines do
    local is_selected = lines[index]:match("^>") ~= nil
    if index == line and not is_selected then
      error("expected sidebar line " .. tostring(line) .. " to be selected, got " .. vim.inspect(lines), 0)
    end
    if index ~= line and is_selected then
      error("expected only sidebar line " .. tostring(line) .. " to be selected, got " .. vim.inspect(lines), 0)
    end
  end
  return lines
end

local function move_cursor(win, row, col)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, col })
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = vim.api.nvim_win_get_buf(win),
    modeline = false,
  })
end

local function press(keys)
  local translated = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(translated, "xt", false)
  vim.cmd("redraw")
end

local ok, err = pcall(function()
  local ark = require("ark")
  local lsp = require("ark.lsp")
  local tmux = require("ark.tmux")

  vim.o.cursorlineopt = "both"

  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = false,
  })

  lsp.start = function(_opts, bufnr)
    started_lsp = started_lsp + 1
    start_bufnrs[#start_bufnrs + 1] = bufnr
    return bufnr
  end

  lsp.status = function(_opts, bufnr)
    status_bufnrs[#status_bufnrs + 1] = bufnr
    return {
      available = true,
      sessionBridgeConfigured = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
      },
    }
  end

  lsp.sync_sessions = function(_opts, bufnr)
    synced_sessions = synced_sessions + 1
    sync_bufnrs[#sync_bufnrs + 1] = bufnr
  end

  lsp.view_open = function(_opts, bufnr)
    view_open_bufnrs[#view_open_bufnrs + 1] = bufnr
    return snapshot(), nil
  end

  lsp.view_state = function()
    return snapshot(), nil
  end

  lsp.view_page = function(_opts, _bufnr, _session_id, offset, limit)
    return page(offset, limit), nil
  end

  lsp.view_sort = function(_opts, _bufnr, _session_id, column_index, direction)
    sort_calls[#sort_calls + 1] = {
      column_index = column_index,
      direction = direction,
    }
    backend.sort = {
      column_index = direction == "" and 0 or column_index,
      direction = direction,
    }
    return snapshot(), nil
  end

  lsp.view_filter = function(_opts, _bufnr, _session_id, column_index, query)
    filter_calls[#filter_calls + 1] = {
      column_index = column_index,
      query = query,
    }
    backend.filters = {}
    if query ~= "" then
      backend.filters[1] = {
        column_index = column_index,
        query = query,
      }
    end
    return snapshot(), nil
  end

  lsp.view_profile = function(_opts, _bufnr, _session_id, column_index)
    profile_calls[#profile_calls + 1] = column_index
    local item = backend.schema[column_index]
    return {
      text = string.format("Profile for %s", item and item.name or "?"),
    }, nil
  end

  lsp.view_code = function()
    code_calls = code_calls + 1
    return {
      code = "mtcars[order(cyl)]",
    }, nil
  end

  lsp.view_export = function(_opts, _bufnr, _session_id, format)
    export_calls = export_calls + 1
    return {
      text = "mpg\tcyl\n22.8\t4",
      format = format,
    }, nil
  end

  lsp.view_cell = function(_opts, _bufnr, _session_id, row_index, column_index)
    cell_calls[#cell_calls + 1] = {
      row_index = row_index,
      column_index = column_index,
    }
    local rows = filtered_rows()
    local value = ((rows[row_index] or {})[column_index] or "")
    return {
      text = string.format("cell[%d,%d]=%s", row_index, column_index, value),
    }, nil
  end

  lsp.view_close = function()
    close_calls = close_calls + 1
    return {
      closed = true,
    }, nil
  end

  tmux.start = function()
    started_pane = started_pane + 1
    return "%99", nil
  end

  tmux.status = function()
    return {
      bridge_ready = true,
      repl_ready = true,
    }
  end

  vim.ui.input = function(opts, on_confirm)
    if not opts.prompt:find("Filter cyl", 1, true) then
      error("unexpected filter prompt: " .. vim.inspect(opts), 0)
    end
    on_confirm("4")
  end

  vim.ui.select = function(items, _opts, on_choice)
    on_choice(items[2])
  end

  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_command.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

  local source_tab = vim.api.nvim_get_current_tabpage()
  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkView mtcars")

  if started_lsp ~= 1 then
    error("expected ArkView to ensure ark_lsp is started once, got " .. tostring(started_lsp), 0)
  end

  if started_pane ~= 1 then
    error("expected ArkView to ensure the managed pane is started once, got " .. tostring(started_pane), 0)
  end

  if synced_sessions ~= 1 then
    error("expected ArkView to sync sessions once, got " .. tostring(synced_sessions), 0)
  end
  if start_bufnrs[1] ~= source_buf then
    error("expected ArkView to start lsp for the source buffer, got " .. vim.inspect(start_bufnrs), 0)
  end
  if sync_bufnrs[1] ~= source_buf then
    error("expected ArkView to sync sessions for the source buffer, got " .. vim.inspect(sync_bufnrs), 0)
  end
  if status_bufnrs[1] ~= source_buf then
    error("expected ArkView runtime status checks to target the source buffer, got " .. vim.inspect(status_bufnrs), 0)
  end
  if view_open_bufnrs[1] ~= source_buf then
    error("expected ArkView requests to use the source buffer, got " .. vim.inspect(view_open_bufnrs), 0)
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  if current_tab == source_tab then
    error("expected ArkView to open a dedicated tabpage", 0)
  end

  local wins = vim.api.nvim_tabpage_list_wins(current_tab)
  if #wins ~= 2 then
    error("expected ArkView to open grid and sidebar windows, got " .. tostring(#wins), 0)
  end

  local grid_win = vim.api.nvim_get_current_win()
  local grid_buf = vim.api.nvim_win_get_buf(grid_win)
  local sidebar_win = nil
  local sidebar_buf = nil
  for _, win in ipairs(wins) do
    local candidate = vim.api.nvim_win_get_buf(win)
    if candidate ~= grid_buf then
      sidebar_win = win
      sidebar_buf = candidate
      break
    end
  end

  if not sidebar_win or not sidebar_buf then
    error("expected ArkView sidebar buffer", 0)
  end

  -- Regression: ArkView should not inherit a global crosshair cursorlineopt,
  -- because it causes visible idle flicker in the table view.
  if vim.wo[grid_win].cursorlineopt ~= "line" then
    error("expected ArkView grid cursorlineopt=line, got " .. vim.inspect(vim.wo[grid_win].cursorlineopt), 0)
  end
  if vim.wo[sidebar_win].cursorlineopt ~= "line" then
    error("expected ArkView sidebar cursorlineopt=line, got " .. vim.inspect(vim.wo[sidebar_win].cursorlineopt), 0)
  end

  local grid_lines = vim.api.nvim_buf_get_lines(grid_buf, 0, -1, false)
  if not (grid_lines[1] or ""):find("mpg", 1, true) then
    error("expected ArkView grid header in current buffer, got " .. vim.inspect(grid_lines), 0)
  end

  local sidebar_lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
  if sidebar_lines[1] ~= "Columns 2" then
    error("unexpected ArkView sidebar header: " .. vim.inspect(sidebar_lines), 0)
  end

  assert_sidebar_selected(sidebar_buf, 3)

  move_cursor(grid_win, 2, header_column(grid_lines, "cyl"))
  local updated_sidebar = assert_sidebar_selected(sidebar_buf, 4)
  if not updated_sidebar[4]:find("cyl", 1, true) then
    error("expected grid cursor move to select cyl column, got " .. vim.inspect(updated_sidebar), 0)
  end

  -- Regression: moving between rows within the same grid column should not
  -- redraw or recenter the sidebar, which causes visible flicker in the UI.
  local original_buf_set_lines = vim.api.nvim_buf_set_lines
  local original_win_set_cursor = vim.api.nvim_win_set_cursor
  local sidebar_redraws = 0
  local sidebar_cursor_moves = 0
  vim.api.nvim_buf_set_lines = function(buf, start, stop, strict, replacement)
    if buf == sidebar_buf then
      sidebar_redraws = sidebar_redraws + 1
    end
    return original_buf_set_lines(buf, start, stop, strict, replacement)
  end
  vim.api.nvim_win_set_cursor = function(win, pos)
    if win == sidebar_win then
      sidebar_cursor_moves = sidebar_cursor_moves + 1
    end
    return original_win_set_cursor(win, pos)
  end

  move_cursor(grid_win, 3, header_column(grid_lines, "cyl"))

  vim.api.nvim_buf_set_lines = original_buf_set_lines
  vim.api.nvim_win_set_cursor = original_win_set_cursor

  if sidebar_redraws ~= 0 or sidebar_cursor_moves ~= 0 then
    error(
      "expected same-column grid movement to avoid touching the sidebar, got redraws="
        .. tostring(sidebar_redraws)
        .. " cursor_moves="
        .. tostring(sidebar_cursor_moves),
      0
    )
  end
  updated_sidebar = assert_sidebar_selected(sidebar_buf, 4)

  move_cursor(sidebar_win, 3, 0)
  assert_sidebar_selected(sidebar_buf, 3)

  press("S")
  if picker_spec == nil then
    error("expected ArkView to open a Snacks picker for column search", 0)
  end
  if picker_spec.title ~= "ArkView Columns" then
    error("unexpected ArkView column picker title: " .. vim.inspect(picker_spec.title), 0)
  end
  assert_sidebar_selected(sidebar_buf, 4)
  if vim.api.nvim_get_current_win() ~= grid_win then
    error("expected schema picker selection to focus the grid", 0)
  end

  move_cursor(sidebar_win, 4, 0)
  press("<CR>")
  if vim.api.nvim_get_current_win() ~= grid_win then
    error("expected sidebar <CR> to jump to the grid", 0)
  end
  if #cell_calls ~= 0 then
    error("expected sidebar <CR> to avoid cell inspection, got " .. vim.inspect(cell_calls), 0)
  end

  press("s")
  if not vim.deep_equal(sort_calls[1], {
    column_index = 2,
    direction = "asc",
  }) then
    error("expected sort on selected column, got " .. vim.inspect(sort_calls), 0)
  end

  updated_sidebar = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
  if not updated_sidebar[4]:find("%[asc%]") then
    error("expected sort badge after toggling cyl sort, got " .. vim.inspect(updated_sidebar), 0)
  end

  grid_lines = vim.api.nvim_buf_get_lines(grid_buf, 0, -1, false)
  if not (grid_lines[2] or ""):find("22.8", 1, true) then
    error("expected sorted rows to place cyl=4 first, got " .. vim.inspect(grid_lines), 0)
  end

  press("/")
  if not vim.deep_equal(filter_calls[1], {
    column_index = 2,
    query = "4",
  }) then
    error("expected filter on selected column, got " .. vim.inspect(filter_calls), 0)
  end

  updated_sidebar = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
  if not updated_sidebar[4]:find("%[asc,filter%]") then
    error("expected filter badge after setting cyl filter, got " .. vim.inspect(updated_sidebar), 0)
  end

  grid_lines = vim.api.nvim_buf_get_lines(grid_buf, 0, -1, false)
  if #grid_lines ~= 2 or not (grid_lines[2] or ""):find("22.8", 1, true) then
    error("expected filtered grid to contain the cyl=4 row only, got " .. vim.inspect(grid_lines), 0)
  end

  press("p")
  if profile_calls[1] ~= 2 then
    error("expected profile request for selected column, got " .. vim.inspect(profile_calls), 0)
  end

  wins = vim.api.nvim_tabpage_list_wins(current_tab)
  if #wins ~= 3 then
    error("expected details split after profile, got " .. tostring(#wins), 0)
  end

  local details_buf = nil
  for _, win in ipairs(wins) do
    local candidate = vim.api.nvim_win_get_buf(win)
    if candidate ~= grid_buf and candidate ~= sidebar_buf then
      details_buf = candidate
      break
    end
  end

  if not details_buf then
    error("expected details buffer after profile", 0)
  end

  local details_lines = vim.api.nvim_buf_get_lines(details_buf, 0, -1, false)
  if details_lines[1] ~= "Column Profile" or details_lines[3] ~= "Profile for cyl" then
    error("unexpected details after profile: " .. vim.inspect(details_lines), 0)
  end

  move_cursor(grid_win, 2, header_column(grid_lines, "cyl"))
  press("c")
  if code_calls ~= 1 then
    error("expected generated code request once, got " .. tostring(code_calls), 0)
  end
  if vim.fn.getreg('"') ~= "mtcars[order(cyl)]" then
    error("expected generated code in default register, got " .. vim.inspect(vim.fn.getreg('"')), 0)
  end

  details_lines = vim.api.nvim_buf_get_lines(details_buf, 0, -1, false)
  if details_lines[1] ~= "Generated Code" or details_lines[3] ~= "mtcars[order(cyl)]" then
    error("unexpected details after generated code: " .. vim.inspect(details_lines), 0)
  end

  press("y")
  if not vim.deep_equal(cell_calls[1], {
    row_index = 1,
    column_index = 2,
  }) then
    error("expected current cell copy request for row 1 col 2, got " .. vim.inspect(cell_calls), 0)
  end
  if vim.fn.getreg('"') ~= "cell[1,2]=4" then
    error("expected copied cell text in default register, got " .. vim.inspect(vim.fn.getreg('"')), 0)
  end

  details_lines = vim.api.nvim_buf_get_lines(details_buf, 0, -1, false)
  if details_lines[1] ~= "Cell" or details_lines[3] ~= "cell[1,2]=4" then
    error("unexpected details after cell copy: " .. vim.inspect(details_lines), 0)
  end

  press("Y")
  if export_calls ~= 1 then
    error("expected export request once, got " .. tostring(export_calls), 0)
  end
  if vim.fn.getreg('"') ~= "mpg\tcyl\n22.8\t4" then
    error("expected exported table in default register, got " .. vim.inspect(vim.fn.getreg('"')), 0)
  end

  details_lines = vim.api.nvim_buf_get_lines(details_buf, 0, -1, false)
  if details_lines[1] ~= "Exported Table" or details_lines[3] ~= "mpg\tcyl" then
    error("unexpected details after export: " .. vim.inspect(details_lines), 0)
  end

  press("<CR>")
  if not vim.deep_equal(cell_calls[2], {
    row_index = 1,
    column_index = 2,
  }) then
    error("expected inspect cell request for row 1 col 2, got " .. vim.inspect(cell_calls), 0)
  end

  details_lines = vim.api.nvim_buf_get_lines(details_buf, 0, -1, false)
  if details_lines[1] ~= "Cell" or details_lines[3] ~= "cell[1,2]=4" then
    error("unexpected details after cell inspect: " .. vim.inspect(details_lines), 0)
  end

  press("q")
  if close_calls < 1 then
    error("expected ArkView to close its session on quit, got " .. tostring(close_calls), 0)
  end
  if vim.api.nvim_get_current_tabpage() ~= source_tab then
    error("expected ArkView quit to return to the source tab", 0)
  end

  if notifications[1] ~= nil then
    error("expected ArkView happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end
end)

vim.notify = original_notify
vim.ui.input = original_input
vim.ui.select = original_select

if not ok then
  error(err, 0)
end
