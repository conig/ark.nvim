local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("ark_view_sticky_header"))
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_view_sticky_header")
local child_script = vim.fs.normalize(run_tmpdir .. "/child.lua")
local ready_path = vim.fs.normalize(run_tmpdir .. "/ready")
local stop_watchdog = ark_test.start_watchdog(60000, "ark_view_sticky_header_tui")

vim.fn.mkdir(run_tmpdir, "p")

local columns = {
  "mpg",
  "cyl",
  "disp",
  "hp",
  "drat",
  "wt",
  "qsec",
  "vs",
  "am",
  "gear",
  "carb",
}

local mtcars_rows = {
  { "21.0", "6", "160", "110", "3.90", "2.620", "16.46", "0", "1", "4", "4" },
  { "21.0", "6", "160", "110", "3.90", "2.875", "17.02", "0", "1", "4", "4" },
  { "22.8", "4", "108", "93", "3.85", "2.320", "18.61", "1", "1", "4", "1" },
  { "21.4", "6", "258", "110", "3.08", "3.215", "19.44", "1", "0", "3", "1" },
  { "18.7", "8", "360", "175", "3.15", "3.440", "17.02", "0", "0", "3", "2" },
  { "18.1", "6", "225", "105", "2.76", "3.460", "20.22", "1", "0", "3", "1" },
  { "14.3", "8", "360", "245", "3.21", "3.570", "15.84", "0", "0", "3", "4" },
  { "24.4", "4", "146.7", "62", "3.69", "3.190", "20.00", "1", "0", "4", "2" },
  { "22.8", "4", "140.8", "95", "3.92", "3.150", "22.90", "1", "0", "4", "2" },
  { "19.2", "6", "167.6", "123", "3.92", "3.440", "18.30", "1", "0", "4", "4" },
  { "17.8", "6", "167.6", "123", "3.92", "3.440", "18.90", "1", "0", "4", "4" },
  { "16.4", "8", "275.8", "180", "3.07", "4.070", "17.40", "0", "0", "3", "3" },
  { "17.3", "8", "275.8", "180", "3.07", "3.730", "17.60", "0", "0", "3", "3" },
  { "15.2", "8", "275.8", "180", "3.07", "3.780", "18.00", "0", "0", "3", "3" },
  { "10.4", "8", "472", "205", "2.93", "5.250", "17.98", "0", "0", "3", "4" },
  { "10.4", "8", "460", "215", "3.00", "5.424", "17.82", "0", "0", "3", "4" },
  { "14.7", "8", "440", "230", "3.23", "5.345", "17.42", "0", "0", "3", "4" },
  { "32.4", "4", "78.7", "66", "4.08", "2.200", "19.47", "1", "1", "4", "1" },
  { "30.4", "4", "75.7", "52", "4.93", "1.615", "18.52", "1", "1", "4", "2" },
  { "33.9", "4", "71.1", "65", "4.22", "1.835", "19.90", "1", "1", "4", "1" },
  { "21.5", "4", "120.1", "97", "3.70", "2.465", "20.01", "1", "0", "3", "1" },
  { "15.5", "8", "318", "150", "2.76", "3.520", "16.87", "0", "0", "3", "2" },
  { "15.2", "8", "304", "150", "3.15", "3.435", "17.30", "0", "0", "3", "2" },
  { "13.3", "8", "350", "245", "3.73", "3.840", "15.41", "0", "0", "3", "4" },
  { "19.2", "8", "400", "175", "3.08", "3.845", "17.05", "0", "0", "3", "2" },
  { "27.3", "4", "79", "66", "4.08", "1.935", "18.90", "1", "1", "4", "1" },
  { "26.0", "4", "120.3", "91", "4.43", "2.140", "16.70", "0", "1", "5", "2" },
  { "30.4", "4", "95.1", "113", "3.77", "1.513", "16.90", "1", "1", "5", "2" },
  { "15.8", "8", "351", "264", "4.22", "3.170", "14.50", "0", "1", "5", "4" },
  { "19.7", "6", "145", "175", "3.62", "2.770", "15.50", "0", "1", "5", "6" },
  { "15.0", "8", "301", "335", "3.54", "3.570", "14.60", "0", "1", "5", "8" },
  { "21.4", "4", "121", "109", "4.11", "2.780", "18.60", "1", "1", "4", "2" },
}

local child_template = [=[
vim.opt.rtp:prepend(%q)

local ark = require("ark")
local lsp = require("ark.lsp")
local tmux = require("ark.tmux")

local columns = %s
local rows = %s

local schema = {}
for index, name in ipairs(columns) do
  schema[index] = {
    index = index,
    name = name,
    class = "numeric",
    type = "double",
  }
end

ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
  view = {
    display = "tab",
  },
})

lsp.start = function(_opts, bufnr)
  return bufnr
end

lsp.status = function()
  return {
    available = true,
    sessionBridgeConfigured = true,
    detachedSessionStatus = {
      lastSessionUpdateStatus = "ready",
    },
  }
end

lsp.sync_sessions = function() end

lsp.view_open = function()
  return {
    session_id = "sticky-header",
    title = "mtcars",
    total_rows = #rows,
    total_columns = #schema,
    schema = vim.deepcopy(schema),
    filters = {},
    sort = {
      column_index = 0,
      direction = "",
    },
  }, nil
end

lsp.view_page = function(_opts, _bufnr, _session_id, offset, limit)
  offset = tonumber(offset or 0) or 0
  limit = tonumber(limit or 0) or 0
  local end_index = limit == 0 and #rows or math.min(#rows, offset + limit)
  local page_rows = {}
  local row_numbers = {}
  for index = offset + 1, end_index do
    page_rows[#page_rows + 1] = vim.deepcopy(rows[index])
    row_numbers[#row_numbers + 1] = index
  end
  return {
    offset = offset,
    limit = limit,
    total_rows = #rows,
    row_numbers = row_numbers,
    rows = page_rows,
  }, nil
end

lsp.view_close = function()
  return { closed = true }, nil
end

tmux.start = function()
  return "%%99", nil
end

tmux.status = function()
  return {
    bridge_ready = true,
    repl_ready = true,
  }
end

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_sticky_header.R")
vim.bo[source_buf].filetype = "r"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

local view = ark.view("mtcars", source_buf)
vim.api.nvim_set_current_win(view.grid_win)
vim.wo[view.grid_win].signcolumn = "yes:2"
vim.api.nvim_win_set_cursor(view.grid_win, { 8, 0 })
vim.cmd("normal! zt")
vim.cmd("redraw!")
vim.fn.writefile({ "ready" }, %q)
]=]

local child_source = string.format(
  child_template,
  repo_root,
  vim.inspect(columns),
  vim.inspect(mtcars_rows),
  ready_path
)

vim.fn.writefile(vim.split(child_source, "\n", { plain = true }), child_script)

local function cleanup()
  ark_test.tmux({ "kill-session", "-t", session_name })
end

local ok, err = xpcall(function()
  pcall(cleanup)
  vim.fn.delete(ready_path)

  local nvim_cmd = table.concat({
    "nvim",
    "-n",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "-c",
    vim.fn.shellescape("set shadafile=NONE"),
    "-c",
    vim.fn.shellescape("luafile " .. child_script),
  }, " ")

  ark_test.tmux({ "new-session", "-d", "-x", "132", "-y", "34", "-s", session_name, nvim_cmd })

  ark_test.wait_for("ArkView sticky-header child", 15000, function()
    return vim.fn.filereadable(ready_path) == 1
  end)
  vim.wait(300, function()
    return false
  end, 300, false)

  local captured = ark_test.tmux({ "capture-pane", "-t", session_name, "-p" })
  local captured_lines = vim.split(captured, "\n", { plain = true })
  local winbar_line = nil
  local header_line = nil
  local class_line = nil
  local header_col = nil
  local header_value_col = nil
  local class_value_col = nil
  local data_col = nil
  for index, line in ipairs(captured_lines) do
    if line:find("mtcars | Rows", 1, true) then
      winbar_line = index
    end
    if line:find("^%s*#%s+|%s+mpg") then
      header_line = index
      header_col = line:find("%S")
      header_value_col = line:find("mpg", 1, true)
      class_line = index + 1
      local class_text = captured_lines[class_line] or ""
      class_value_col = class_text:find("<numeric>", 1, true)
      local data_line = captured_lines[index + 2] or ""
      data_col = data_line:find("%S")
      break
    end
  end

  -- Regression: the sticky header must occupy the top visible grid rows,
  -- include the class row, and align with grid text when the user's config
  -- reserves sign/status columns.
  if
    not winbar_line
    or not header_line
    or not class_line
    or header_line ~= winbar_line + 1
    or class_line ~= winbar_line + 2
    or not header_col
    or not header_value_col
    or not class_value_col
    or header_col ~= data_col
    or class_value_col ~= header_value_col
  then
    ark_test.fail("expected visible sticky ArkView column header after scrolling, captured pane:\n" .. captured)
  end
end, debug.traceback)

stop_watchdog()
pcall(cleanup)

if not ok then
  error(err, 0)
end
