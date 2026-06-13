vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_edit_protection")

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

local function stop_insert_mode()
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    ark_test.wait_for("normal mode", 4000, function()
      return vim.fn.mode() == "n"
    end)
  end
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end

local function wait_for_line_text(row, text)
  ark_test.wait_for("line " .. tostring(row) .. " to become " .. text, 4000, function()
    return vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] == text
  end)
end

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "old_call()" })
local ok, submit_err = require("ark.console").submit(bufnr)
if not ok then
  ark_test.fail("failed to submit initial console input: " .. tostring(submit_err))
end

ark_test.wait_for("initial transcript output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> console saw: old_call%(%)") ~= nil
end)

stop_insert_mode()
local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local status = require("ark.console").status(bufnr)
if type(status) ~= "table" or tonumber(status.input_start) == nil or status.input_start < 2 then
  ark_test.fail("expected prior transcript before active input: " .. vim.inspect({
    status = status,
    lines = before,
  }))
end

vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "arrow_draft()" })
vim.api.nvim_win_set_cursor(0, { status.input_start + 1, #"arrow_draft()" })
feed("i<Up><Esc>")
ark_test.wait_for("insert-mode up should recall previous console history", 4000, function()
  local current_status = require("ark.console").status(bufnr)
  local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, current_status.input_start, -1, false), "\n")
  return input == "old_call()"
end)
local up_cursor = vim.api.nvim_win_get_cursor(0)
if up_cursor[1] < require("ark.console").status(bufnr).input_start + 1 then
  ark_test.fail("insert-mode up moved cursor out of active input: " .. vim.inspect(up_cursor))
end
feed("i<Down><Esc>")
ark_test.wait_for("insert-mode down should restore draft input", 4000, function()
  local current_status = require("ark.console").status(bufnr)
  local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, current_status.input_start, -1, false), "\n")
  return input == "arrow_draft()"
end)
status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "" })
before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

-- Old submitted input and output must remain readable/yankable, but normal
-- edit commands must not be able to mutate them. The active input line is the
-- only writable region.
vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("A_MUTATE<Esc>")
wait_for_line_text(1, before[1])

vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("dd")
wait_for_line_text(1, before[1])

vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("o")
ark_test.wait_for("normal-mode o to keep cursor in active input", 4000, function()
  local current_status = require("ark.console").status(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  return type(current_status) == "table" and cursor[1] >= current_status.input_start + 1
end)
local after_o = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
if vim.inspect(after_o) ~= vim.inspect(before) then
  ark_test.fail("normal-mode o on protected transcript changed console text: " .. vim.inspect({
    before = before,
    after = after_o,
  }))
end
stop_insert_mode()

local after_invalid_edits = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
if vim.inspect(after_invalid_edits) ~= vim.inspect(before) then
  ark_test.fail("protected transcript changed after old-output edits: " .. vim.inspect({
    before = before,
    after = after_invalid_edits,
  }))
end

vim.api.nvim_win_set_cursor(0, { 1, 0 })
feed("Vjy")
ark_test.wait_for("visual yank from protected output", 4000, function()
  return vim.fn.getreg('"'):find("old_call()", 1, true) ~= nil
end)
after_invalid_edits = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
if vim.inspect(after_invalid_edits) ~= vim.inspect(before) then
  ark_test.fail("visual yank should not mutate protected transcript: " .. vim.inspect({
    before = before,
    after = after_invalid_edits,
  }))
end

-- A paste or external edit into the transcript can be followed immediately by
-- a managed send. The send must not preserve the invalid paste in the console
-- snapshot or prevent the later code from reaching R.
vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "bad_paste_one()", "bad_paste_two()" })
local send_ok, send_err = require("ark.console").send_text(bufnr, "after_bad_paste()")
if not send_ok then
  ark_test.fail("failed to send after protected paste: " .. tostring(send_err))
end

ark_test.wait_for("send after protected paste output", 10000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> console saw: after_bad_paste%(%)") ~= nil
end)

local after_bad_paste_send = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local after_bad_paste_transcript = table.concat(after_bad_paste_send, "\n")
if after_bad_paste_transcript:find("bad_paste_one()", 1, true)
  or after_bad_paste_transcript:find("bad_paste_two()", 1, true)
then
  ark_test.fail("protected paste leaked into console transcript snapshot: " .. vim.inspect(after_bad_paste_send))
end
if not after_bad_paste_transcript:find("\nafter_bad_paste()\n", 1, true) then
  ark_test.fail("managed send input should remain visible after protected paste: " .. vim.inspect(after_bad_paste_send))
end

status = require("ark.console").status(bufnr)
vim.api.nvim_win_set_cursor(0, { status.input_start + 1, 0 })
feed("Anew_call()<Esc>")
wait_for_line_text(status.input_start + 1, "new_call()")

local ok_submit, current_submit_err = require("ark.console").submit(bufnr)
if not ok_submit then
  ark_test.fail("failed to submit editable current input: " .. tostring(current_submit_err))
end

ark_test.wait_for("current input submission output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> console saw: new_call%(%)") ~= nil
end)

stop_watchdog()
