vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_ctrl_c_fresh_input")

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
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "draft_to_cancel()" })
vim.api.nvim_win_set_cursor(winid, { status.input_start + 1, #"draft_to_cancel()" })
vim.cmd("startinsert")

-- Regression: at an idle prompt, Ctrl-C should behave like a regular R REPL:
-- abandon the current draft visibly and place the cursor on a fresh blank
-- prompt, without submitting the abandoned draft to R.
vim.api.nvim_feedkeys(vim.keycode("<C-c>"), "xt", false)

ark_test.wait_for("Ctrl-C to create fresh input", 4000, function()
  local current_status = require("ark.console").status(bufnr)
  if type(current_status) ~= "table" then
    return false
  end
  local active_input = vim.api.nvim_buf_get_lines(bufnr, current_status.input_start, -1, false)
  local transcript = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, current_status.input_start, false), "\n")
  return vim.inspect(active_input) == vim.inspect({ "" })
    and transcript:find("draft_to_cancel()", 1, true) ~= nil
end)

if fake_r_log_text():find("draft_to_cancel()", 1, true) then
  ark_test.fail("Ctrl-C submitted the abandoned draft to R: " .. fake_r_log_text())
end

local after_status = require("ark.console").status(bufnr)
local cursor = vim.api.nvim_win_get_cursor(winid)
if cursor[1] ~= after_status.input_start + 1 or cursor[2] ~= 0 then
  ark_test.fail("Ctrl-C should leave cursor at the fresh prompt: " .. vim.inspect({
    cursor = cursor,
    status = after_status,
  }))
end

vim.print({
  nvim_console_ctrl_c_fresh_input = "ok",
})

stop_watchdog()
