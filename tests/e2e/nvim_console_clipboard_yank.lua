vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_clipboard_yank")

_G.ark_test_clipboard = {
  plus = { lines = { "" }, regtype = "v" },
  star = { lines = { "" }, regtype = "v" },
}
vim.g.clipboard = {
  name = "ark-test-clipboard",
  copy = {
    ["+"] = function(lines, regtype)
      _G.ark_test_clipboard.plus = { lines = lines, regtype = regtype }
    end,
    ["*"] = function(lines, regtype)
      _G.ark_test_clipboard.star = { lines = lines, regtype = regtype }
    end,
  },
  paste = {
    ["+"] = function()
      local value = _G.ark_test_clipboard.plus
      return value.lines, value.regtype
    end,
    ["*"] = function()
      local value = _G.ark_test_clipboard.star
      return value.lines, value.regtype
    end,
  },
}

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

local winid = vim.fn.bufwinid(bufnr)
if type(winid) ~= "number" or winid <= 0 then
  ark_test.fail("console buffer is not visible")
end
vim.api.nvim_set_current_win(winid)

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "clipboard_line_one",
  "visual_word",
})

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

local function wait_for_clipboard(label, expected)
  ark_test.wait_for(label, 5000, function()
    return vim.fn.getreg("+") == expected
  end)
end

vim.fn.setreg("+", "")
vim.api.nvim_win_set_cursor(winid, { 1, 0 })
feed("yy")
wait_for_clipboard("normal line yank uses system clipboard", "clipboard_line_one\n")

vim.fn.setreg("+", "")
vim.api.nvim_win_set_cursor(winid, { 2, 0 })
feed("viwy")
wait_for_clipboard("visual yank uses system clipboard", "visual_word")

vim.print({
  nvim_console_clipboard_yank = "ok",
})

stop_watchdog()
