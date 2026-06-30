vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_view_open_layout_protection")

local original_columns = vim.o.columns
local original_lines = vim.o.lines
vim.o.columns = 60
vim.o.lines = 24

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_open_layout_protection.R")
vim.bo[source_buf].filetype = "r"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

local close_calls = 0
local lsp = {
  view_open = function(_opts, _bufnr, expr)
    return {
      session_id = "view-test",
      title = expr,
      schema = {
        { index = 1, name = "mpg" },
        { index = 2, name = "cyl" },
        { index = 3, name = "disp" },
        { index = 4, name = "hp" },
        { index = 5, name = "wt" },
      },
      total_rows = 3,
      total_columns = 5,
      filters = {},
      sort = {},
    }, nil
  end,
  view_page = function()
    return {
      offset = 0,
      limit = 0,
      total_rows = 3,
      rows = {
        { "21.0", "6", "160", "110", "2.62" },
        { "21.0", "6", "160", "110", "2.88" },
        { "22.8", "4", "108", "93", "2.32" },
      },
      row_numbers = { "Mazda RX4", "Mazda RX4 Wag", "Datsun 710" },
    }, nil
  end,
  view_close = function()
    close_calls = close_calls + 1
    return { closed = true }, nil
  end,
}

local notifications = {}
vim.cmd("startinsert")

local state = require("ark.view").open({
  expr = "mtcars",
  source_bufnr = source_buf,
  options = {},
  lsp = lsp,
  notify = function(message, level)
    notifications[#notifications + 1] = {
      message = tostring(message),
      level = level,
    }
  end,
})

if type(state) ~= "table" then
  ark_test.fail("expected ArkView to open, got " .. vim.inspect(state))
end

local mode = vim.api.nvim_get_mode().mode
if mode ~= "n" then
  ark_test.fail("expected ArkView to start in normal mode, got mode=" .. tostring(mode))
end
vim.api.nvim_feedkeys("i", "x", false)
mode = vim.api.nvim_get_mode().mode
if mode ~= "n" then
  ark_test.fail("expected ArkView insert hotkey to be disabled, got mode=" .. tostring(mode))
end

if vim.bo[state.grid_buf].modifiable or not vim.bo[state.grid_buf].readonly then
  ark_test.fail("expected ArkView grid buffer to be readonly and nomodifiable")
end
if vim.bo[state.sidebar_buf].modifiable or not vim.bo[state.sidebar_buf].readonly then
  ark_test.fail("expected ArkView sidebar buffer to be readonly and nomodifiable")
end

local grid_width = vim.api.nvim_win_get_width(state.grid_win)
local sidebar_width = vim.api.nvim_win_get_width(state.sidebar_win)
if grid_width <= sidebar_width then
  ark_test.fail("expected ArkView grid to remain wider than column list in narrow UIs, got " .. vim.inspect({
    grid_width = grid_width,
    sidebar_width = sidebar_width,
  }))
end
if sidebar_width > math.floor(vim.o.columns * 0.25) then
  ark_test.fail("expected ArkView column list to stay close to a 20% sidebar, got " .. vim.inspect({
    columns = vim.o.columns,
    sidebar_width = sidebar_width,
  }))
end
if grid_width < sidebar_width * 3 then
  ark_test.fail("expected ArkView data grid to be at least 3x wider than column list, got " .. vim.inspect({
    grid_width = grid_width,
    sidebar_width = sidebar_width,
  }))
end

local before = vim.api.nvim_buf_get_lines(state.grid_buf, 0, -1, false)
local edit_ok = pcall(vim.api.nvim_buf_set_lines, state.grid_buf, 0, 0, false, { "SHOULD_NOT_EDIT" })
if edit_ok then
  ark_test.fail("ArkView grid buffer unexpectedly accepted direct edits")
end
local after = vim.api.nvim_buf_get_lines(state.grid_buf, 0, -1, false)
if not vim.deep_equal(before, after) then
  ark_test.fail("typing in ArkView grid should not edit table text: " .. vim.inspect({
    before = before,
    after = after,
  }))
end

require("ark.view").close()
if close_calls ~= 1 then
  ark_test.fail("expected ArkView close to close runtime session once, got " .. tostring(close_calls))
end
if #notifications ~= 0 then
  ark_test.fail("expected ArkView layout/protection happy path to avoid notifications, got " .. vim.inspect(notifications))
end

vim.o.columns = original_columns
vim.o.lines = original_lines

vim.print({
  ark_view_open_layout_protection = "ok",
})

stop_watchdog()
