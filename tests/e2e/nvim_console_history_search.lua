vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_history_search")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
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
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end


local console = require("ark.console")
local function input()
  local status = console.status(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false), "\n")
end
local function draft(text)
  vim.api.nvim_buf_set_lines(bufnr, console.status(bufnr).input_start, -1, false, vim.split(text, "\n", { plain = true }))
end

draft("first_call()")
assert(console.submit(bufnr))
ark_test.wait_for("first output", 4000, function()
  return console.status(bufnr).prompt_state == "top-level"
end)
draft("second_call()")
assert(console.submit(bufnr))
ark_test.wait_for("second output", 4000, function()
  return console.status(bufnr).prompt_state == "top-level"
end)
draft("keep_this_draft()")

-- Capture the canonical asynchronous UI boundary; console and PTY stay real.
local original_select, original_input = vim.ui.select, vim.ui.input
local items, choose, answer, picker_options
vim.ui.select = function(candidates, options, callback)
  items, choose, picker_options = candidates, callback, options
end
vim.ui.input = function(_, callback)
  answer = callback
end
vim.cmd("runtime plugin/ark.lua")
vim.cmd("Ark console history first")
assert(#items == 1 and items[1].text == "first_call()")
choose(items[1])
assert(input() == "first_call()")
assert(#console.status(bufnr).history == 2, "selection executed a command")
assert(console.history_next(bufnr))
assert(input() == "second_call()")
assert(console.history_next(bufnr))
assert(input() == "keep_this_draft()")

assert(console.history_search(bufnr))
answer("")
assert(#items == 2 and items[1].text == "second_call()")
choose(nil)
assert(input() == "keep_this_draft()", "cancel changed draft")
local multiline = "multi(\n  2\n)"
draft(multiline)
assert(console.submit(bufnr))
ark_test.wait_for("multiline output", 4000, function()
  return console.status(bufnr).prompt_state == "top-level"
end)
draft("multiline_draft()")
assert(console.history_search(bufnr, "multi"))
assert(not picker_options.format_item(items[1]):find("\n", 1, true))
choose(items[1])
assert(input() == multiline)
assert(#console.status(bufnr).history == 3)
assert(console.history_next(bufnr))
assert(input() == "multiline_draft()")

assert(console.history_search(bufnr, "first"))
draft("edited_while_picker_open()")
choose(items[1])
assert(input() == "edited_while_picker_open()", "stale picker overwrote a newer draft")
assert(console.history_search(bufnr, "second"))
vim.api.nvim_buf_delete(bufnr, { force = true })
choose(items[1]) -- Closing the console while the picker is open is harmless.
vim.ui.select, vim.ui.input = original_select, original_input
stop_watchdog()
