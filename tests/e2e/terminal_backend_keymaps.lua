vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "terminal_backend_keymaps")

local run_tmpdir = ark_test.run_tmpdir()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> mtcars'",
  "while IFS= read -r _line; do :; done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local source_bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_bufnr)
vim.api.nvim_buf_set_name(source_bufnr, vim.fs.normalize(run_tmpdir .. "/terminal_backend_keymaps.R"))
vim.bo[source_bufnr].filetype = "r"
vim.api.nvim_buf_set_lines(source_bufnr, 0, -1, false, { "mtcars" })

local view_calls = {}
local target_view_calls = {}
package.loaded["ark"] = {
  view_under_cursor = function(bufnr)
    view_calls[#view_calls + 1] = bufnr
  end,
  targets_view_pick = function(bufnr)
    target_view_calls[#target_view_calls + 1] = bufnr
  end,
}

local terminal = require("ark.terminal")
local pane_id, pane_err = terminal.start({
  configure_slime = false,
  filetypes = { "r" },
  keymaps = {
    prefix = "<leader>r",
  },
  terminal = {
    console_frontend = "raw",
    launcher = launcher,
    split_direction = "horizontal",
    split_position = "botright",
    split_size = 4,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})
if not pane_id then
  stop_watchdog()
  ark_test.fail("failed to start terminal backend: " .. tostring(pane_err))
end

local session = terminal.session()
if type(session) ~= "table" or type(session.terminal_bufnr) ~= "number" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend did not expose a terminal buffer: " .. vim.inspect(session))
end

local bufnr = session.terminal_bufnr
if vim.b[bufnr].ark_terminal ~= true then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend did not mark vim.b.ark_terminal")
end
if vim.b[bufnr].ark_terminal_source_bufnr ~= source_bufnr then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend did not remember the source buffer")
end

local winid = vim.fn.bufwinid(bufnr)
if type(winid) == "number" and winid > 0 then
  vim.api.nvim_set_current_win(winid)
end

local view_map = vim.fn.maparg("<leader>rv", "n", false, true)
if type(view_map) ~= "table" or type(view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map normal <leader>rv to ArkView: " .. vim.inspect(view_map))
end

local visual_view_map = vim.fn.maparg("<leader>rv", "x", false, true)
if type(visual_view_map) ~= "table" or type(visual_view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map visual <leader>rv to ArkView: " .. vim.inspect(visual_view_map))
end

local upper_view_map = vim.fn.maparg("<leader>rV", "n", false, true)
if type(upper_view_map) ~= "table" or type(upper_view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map normal <leader>rV to ArkView: " .. vim.inspect(upper_view_map))
end

local visual_upper_view_map = vim.fn.maparg("<leader>rV", "x", false, true)
if type(visual_upper_view_map) ~= "table" or type(visual_upper_view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map visual <leader>rV to ArkView: " .. vim.inspect(visual_upper_view_map))
end

-- Regression: users press ArkView mappings from the active R prompt, where a
-- terminal buffer is in terminal-job mode rather than normal mode.
local terminal_upper_view_map = vim.fn.maparg("<leader>rV", "t", false, true)
if type(terminal_upper_view_map) ~= "table" or type(terminal_upper_view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map terminal-mode <leader>rV to ArkView: " .. vim.inspect(terminal_upper_view_map))
end

local target_view_map = vim.fn.maparg("<leader>tv", "n", false, true)
if type(target_view_map) ~= "table" or type(target_view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map normal <leader>tv to target ArkView: " .. vim.inspect(target_view_map))
end

vim.cmd("startinsert")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>rV", true, false, true), "xt", false)
local keypress_opened_view = vim.wait(1000, function()
  return view_calls[1] == bufnr
end, 20, false)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-\\><C-n>", true, false, true), "xt", false)
if not keypress_opened_view then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal-mode <leader>rV keypress should open ArkView, got " .. vim.inspect(view_calls))
end

view_map.callback()
upper_view_map.callback()
terminal_upper_view_map.callback()
if view_calls[1] ~= bufnr or view_calls[2] ~= bufnr or view_calls[3] ~= bufnr or view_calls[4] ~= bufnr then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal ArkView mappings should target the terminal buffer, got " .. vim.inspect(view_calls))
end

target_view_map.callback()
if target_view_calls[1] ~= bufnr then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal <leader>tv should target the terminal buffer, got " .. vim.inspect(target_view_calls))
end

package.loaded["ark"] = nil
local real_ark = require("ark")
local lsp = require("ark.lsp")
local real_view_open_exprs = {}
local real_view_open_bufnrs = {}

real_ark.setup({
  auto_start_lsp = false,
  auto_start_pane = false,
  configure_slime = false,
  session = {
    backend = "terminal",
  },
  terminal = {
    console_frontend = "raw",
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

lsp.status = function()
  return {
    available = true,
    sessionBridgeConfigured = true,
    detachedSessionStatus = {
      lastSessionUpdateStatus = "ready",
    },
  }
end
lsp.view_open = function(_opts, view_bufnr, expr)
  real_view_open_bufnrs[#real_view_open_bufnrs + 1] = view_bufnr
  real_view_open_exprs[#real_view_open_exprs + 1] = expr
  return {
    session_id = "terminal-keymap-view",
    title = expr,
    total_rows = 1,
    total_columns = 1,
    schema = {
      { index = 1, name = "x", class = "numeric", type = "double" },
    },
    filters = {},
    sort = { column_index = 0, direction = "" },
  }, nil
end
lsp.view_page = function()
  return {
    offset = 0,
    limit = 100,
    total_rows = 1,
    row_numbers = { 1 },
    rows = {
      { "1" },
    },
  }, nil
end
lsp.view_state = function()
  return {
    session_id = "terminal-keymap-view",
    title = "mtcars",
    total_rows = 1,
    total_columns = 1,
    schema = {
      { index = 1, name = "x", class = "numeric", type = "double" },
    },
    filters = {},
    sort = { column_index = 0, direction = "" },
  }, nil
end
terminal.status = function()
  return {
    bridge_ready = true,
    repl_ready = true,
  }
end

vim.api.nvim_set_current_win(winid)
vim.cmd("startinsert")
local terminal_rendered_input = vim.wait(1000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("mtcars", 1, true) ~= nil
end, 20, false)
if not terminal_rendered_input then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal did not render mtcars before ArkView keypress")
end
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>rV", true, false, true), "xt", false)
local real_keypress_opened_view = vim.wait(1000, function()
  return real_view_open_exprs[1] ~= nil
end, 20, false)
if not real_keypress_opened_view then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal-mode <leader>rV keypress should open real ArkView, got no view requests")
end
if real_view_open_exprs[1] ~= "mtcars" or real_view_open_bufnrs[1] ~= source_bufnr then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal-mode <leader>rV should view mtcars from the source buffer, got " .. vim.inspect({
    exprs = real_view_open_exprs,
    bufnrs = real_view_open_bufnrs,
    source_bufnr = source_bufnr,
  }))
end

terminal.stop()
stop_watchdog()

vim.print({
  terminal_backend_keymaps = "ok",
})
