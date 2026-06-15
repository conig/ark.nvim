vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_insert_paste_is_edit")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
local fake_r_log = vim.fs.normalize(run_tmpdir .. "/fake-r.log")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "log=" .. vim.fn.shellescape(fake_r_log),
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf '%s\\n' \"$line\" >> \"$log\"",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

vim.g.ark_console_terminal_ui = true

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

local winid = vim.fn.bufwinid(bufnr)
if type(winid) ~= "number" or winid <= 0 then
  ark_test.fail("console buffer is not visible")
end
vim.api.nvim_set_current_win(winid)

local function current_input()
  local status = require("ark.console").status(bufnr)
  if type(status) ~= "table" then
    ark_test.fail("missing Ark console status")
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false), "\n")
end

local function fake_r_log_text()
  if vim.fn.filereadable(fake_r_log) ~= 1 then
    return ""
  end
  return table.concat(vim.fn.readfile(fake_r_log), "\n")
end

ark_test.wait_for("console prompt ready", 5000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.prompt_state == "top-level"
end)

local status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "" })
vim.api.nvim_win_set_cursor(winid, { status.input_start + 1, 0 })
vim.cmd("startinsert")

-- Regression: pasting a yanked transcript line into the active input should be
-- an edit. The console must not submit merely because the pasted register is
-- linewise and therefore carries a trailing newline.
local paste_ok = vim.paste({ "pasted_from_transcript()", "" }, -1)
if paste_ok ~= true then
  ark_test.fail("vim.paste() rejected Ark console paste")
end
vim.wait(300)

if current_input() ~= "pasted_from_transcript()" then
  ark_test.fail("linewise paste should remain in editable input: " .. vim.inspect({
    input = current_input(),
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
  }))
end

if fake_r_log_text():find("pasted_from_transcript()", 1, true) then
  ark_test.fail("linewise paste submitted before Enter: " .. fake_r_log_text())
end

local submit_ok, submit_err = require("ark.console").submit(bufnr)
if not submit_ok then
  ark_test.fail("failed to submit pasted console input: " .. tostring(submit_err))
end

ark_test.wait_for("pasted input reaches R after explicit submit", 5000, function()
  return fake_r_log_text():find("pasted_from_transcript()", 1, true) ~= nil
end)

vim.print({
  nvim_console_insert_paste_is_edit = "ok",
})

stop_watchdog()
