vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_ctrl_d_scroll")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "for i in $(seq 1 80); do",
  "  printf 'history line %03d\\n' \"$i\"",
  "done",
  "printf '> '",
  "while IFS= read -r line; do",
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
pcall(vim.api.nvim_win_set_height, winid, 12)

ark_test.wait_for("console transcript ready", 10000, function()
  local status = require("ark.console").status(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return type(status) == "table"
    and status.running == true
    and status.prompt_state == "top-level"
    and table.concat(lines, "\n"):find("history line 080", 1, true) ~= nil
end)

vim.cmd("stopinsert")
ark_test.wait_for("console normal mode", 5000, function()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "n"
end)

-- Regression: Ark's terminal UI should keep Vim's normal-mode half-page
-- transcript scrolling. Ctrl-U already moves up; Ctrl-D should move down
-- symmetrically instead of being captured as console EOF.
vim.api.nvim_win_set_cursor(winid, { 45, 0 })
vim.fn.winrestview({
  lnum = 45,
  topline = 35,
  col = 0,
  curswant = 0,
})

local before_up = vim.fn.winsaveview().topline
vim.api.nvim_feedkeys(vim.keycode("<C-u>"), "mx", false)
local after_up = vim.fn.winsaveview().topline
if after_up >= before_up then
  stop_watchdog()
  ark_test.fail("Ctrl-U should scroll the Ark console transcript up: " .. vim.inspect({
    before_up = before_up,
    after_up = after_up,
  }))
end

vim.api.nvim_feedkeys(vim.keycode("<C-d>"), "mx", false)
local after_down = vim.fn.winsaveview().topline
if after_down <= after_up then
  stop_watchdog()
  ark_test.fail("Ctrl-D should scroll the Ark console transcript down: " .. vim.inspect({
    before_up = before_up,
    after_up = after_up,
    after_down = after_down,
  }))
end

vim.print({
  nvim_console_ctrl_d_scroll = {
    before_up = before_up,
    after_up = after_up,
    after_down = after_down,
  },
})

stop_watchdog()
