vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(45000, "nvim_console_real_r")

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_real_r")
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/real-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "exec R --quiet --no-save --no-restore",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start real R nvim console: " .. tostring(err))
end

ark_test.wait_for("real R top-level prompt", 15000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { [[cat("ark-nvim-console-real-r-ok\n"); flush.console()]] })
local ok, submit_err = require("ark.console").submit(bufnr)
if not ok then
  ark_test.fail("failed to submit real R console input: " .. tostring(submit_err))
end

ark_test.wait_for("real R console output", 15000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> ark%-nvim%-console%-real%-r%-ok") ~= nil
end)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local transcript = table.concat(lines, "\n")
if transcript:find("^#> >", 1, false) or transcript:find("\n#> >", 1, false) then
  ark_test.fail("real R prompt should not be recorded as output: " .. vim.inspect(lines))
end
if not transcript:find([[cat("ark-nvim-console-real-r-ok\n"); flush.console()]], 1, true) then
  ark_test.fail("real R input should remain as R code: " .. vim.inspect(lines))
end

local status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "{" })
local block_open_ok, block_open_err = require("ark.console").submit(bufnr)
if not block_open_ok then
  ark_test.fail("failed to submit real R block opener: " .. tostring(block_open_err))
end

ark_test.wait_for("real R continuation after block opener", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "continuation"
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { [[cat("ark-nvim-console-real-r-multiline\n"); flush.console()]] })
local block_body_ok, block_body_err = require("ark.console").submit(bufnr)
if not block_body_ok then
  ark_test.fail("failed to submit real R block body: " .. tostring(block_body_err))
end

ark_test.wait_for("real R continuation after block body", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "continuation"
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "}" })
local block_close_ok, block_close_err = require("ark.console").submit(bufnr)
if not block_close_ok then
  ark_test.fail("failed to submit real R block closer: " .. tostring(block_close_err))
end

ark_test.wait_for("real R multiline output", 15000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> ark%-nvim%-console%-real%-r%-multiline") ~= nil
end)

lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
transcript = table.concat(lines, "\n")
if not transcript:find('\n{\n', 1, true)
  or not transcript:find([[cat("ark-nvim-console-real-r-multiline\n"); flush.console()]], 1, true)
  or not transcript:find('\n}\n', 1, true)
then
  ark_test.fail("real R multiline input should remain as R code: " .. vim.inspect(lines))
end

status = require("ark.console").status(bufnr)
local buffered_block = [[{cat("ark-nvim-console-real-r-buffered-block\n"); flush.console()}]]
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { buffered_block })
vim.api.nvim_win_set_cursor(0, { status.input_start + 1, 1 })
local buffered_newline_ok, buffered_newline_err = require("ark.console").insert_newline(bufnr)
if not buffered_newline_ok then
  ark_test.fail("failed to split real R buffered block opener: " .. tostring(buffered_newline_err))
end
vim.api.nvim_win_set_cursor(0, { status.input_start + 2, #"cat(\"ark-nvim-console-real-r-buffered-block\\n\"); flush.console()" })
buffered_newline_ok, buffered_newline_err = require("ark.console").insert_newline(bufnr)
if not buffered_newline_ok then
  ark_test.fail("failed to split real R buffered block closer: " .. tostring(buffered_newline_err))
end
local buffered_ok, buffered_err = require("ark.console").submit(bufnr)
if not buffered_ok then
  ark_test.fail("failed to submit real R buffered multiline input: " .. tostring(buffered_err))
end

ark_test.wait_for("real R buffered multiline output", 15000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> ark%-nvim%-console%-real%-r%-buffered%-block") ~= nil
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, {
  [[ark_console_browser_probe <- function() { browser(); cat("ark-nvim-console-real-r-browser-done\n"); flush.console() }]],
})
local browser_def_ok, browser_def_err = require("ark.console").submit(bufnr)
if not browser_def_ok then
  ark_test.fail("failed to submit real R browser probe definition: " .. tostring(browser_def_err))
end

ark_test.wait_for("real R prompt after browser probe definition", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "top-level"
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "ark_console_browser_probe()" })
local browser_call_ok, browser_call_err = require("ark.console").submit(bufnr)
if not browser_call_ok then
  ark_test.fail("failed to call real R browser probe: " .. tostring(browser_call_err))
end

ark_test.wait_for("real R browser prompt state", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "browser"
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "c" })
local browser_continue_ok, browser_continue_err = require("ark.console").submit(bufnr)
if not browser_continue_ok then
  ark_test.fail("failed to continue real R browser prompt: " .. tostring(browser_continue_err))
end

ark_test.wait_for("real R browser continuation output", 15000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> ark%-nvim%-console%-real%-r%-browser%-done") ~= nil
end)

lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
transcript = table.concat(lines, "\n")
if transcript:find("^#> Browse%[", 1, false) or transcript:find("\n#> Browse%[", 1, false) then
  ark_test.fail("real R browser prompt should not be recorded as output: " .. vim.inspect(lines))
end

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "Sys.sleep(30)" })
local sleep_ok, sleep_err = require("ark.console").submit(bufnr)
if not sleep_ok then
  ark_test.fail("failed to submit real R sleep input: " .. tostring(sleep_err))
end

ark_test.wait_for("real R busy prompt state", 5000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "busy"
end)

local interrupt_ok, interrupt_err = require("ark.console").interrupt(bufnr)
if not interrupt_ok then
  ark_test.fail("failed to interrupt real R console input: " .. tostring(interrupt_err))
end

ark_test.wait_for("real R prompt after interrupt", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.running == true and current.prompt_state == "top-level"
end)

local eof_ok, eof_err = require("ark.console").eof(bufnr)
if not eof_ok then
  ark_test.fail("failed to send EOF to real R console: " .. tostring(eof_err))
end

ark_test.wait_for("real R exit after EOF", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.running == false and current.exit_code == 0
end)

stop_watchdog()
