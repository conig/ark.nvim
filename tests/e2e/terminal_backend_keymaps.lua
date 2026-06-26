vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "terminal_backend_keymaps")

local run_tmpdir = ark_test.run_tmpdir()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf 'mtcars\\n'",
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

local target_view_map = vim.fn.maparg("<leader>tv", "n", false, true)
if type(target_view_map) ~= "table" or type(target_view_map.callback) ~= "function" then
  terminal.stop()
  stop_watchdog()
  ark_test.fail("terminal backend should map normal <leader>tv to target ArkView: " .. vim.inspect(target_view_map))
end

view_map.callback()
upper_view_map.callback()
if view_calls[1] ~= bufnr or view_calls[2] ~= bufnr then
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

terminal.stop()
stop_watchdog()

vim.print({
  terminal_backend_keymaps = "ok",
})
