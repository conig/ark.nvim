vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_line_numbers")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "for ((i = 1; i <= 1200; i++)); do printf 'history %s\\n' \"$i\"; done",
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

ark_test.wait_for("console transcript and prompt", 5000, function()
  local status = require("ark.console").status(bufnr)
  return status and status.prompt_state == "top-level" and vim.api.nvim_buf_line_count(bufnr) > 1200
end)
vim.api.nvim_win_set_cursor(winid, { vim.api.nvim_buf_line_count(bufnr), 0 })

local function window_state()
  vim.cmd("redraw")
  local column = vim.wo[winid].statuscolumn
  if column == "" then
    column = (vim.wo[winid].number or vim.wo[winid].relativenumber) and "%l " or ""
  end
  return {
    gutter = vim.api.nvim_eval_statusline(column, { winid = winid, use_statuscol_lnum = 1 }).str,
    textoff = vim.fn.getwininfo(winid)[1].textoff,
    conceallevel = vim.wo[winid].conceallevel,
  }
end

local function wait_for_window_state(label, opts)
  ark_test.wait_for(label, 5000, function()
    local concealcursor = vim.wo[winid].concealcursor or ""
    return (window_state().gutter:find("%d") ~= nil) == opts.numbers_visible
      and vim.wo[winid].conceallevel == opts.conceallevel
      and concealcursor:find("i", 1, true) == nil
  end)
end

local function wait_for_mode(label, predicate)
  ark_test.wait_for(label, 5000, function()
    local mode = vim.api.nvim_get_mode().mode
    return type(mode) == "string" and predicate(mode)
  end)
end

wait_for_window_state("terminal console normal mode shows line numbers and output prefixes", {
  numbers_visible = true,
  conceallevel = 0,
})

-- The current absolute line number must share the relative numbers' right
-- edge rather than protruding left in Neovim's default hybrid layout.
local current_line = vim.api.nvim_win_get_cursor(winid)[1]
local function number_right_edge(line)
  local column = vim.api.nvim_eval_statusline(vim.wo[winid].statuscolumn, {
    winid = winid,
    use_statuscol_lnum = line,
  }).str
  assert(column:find("%d"), "navigation line number is missing")
  local right_edge = column:match(".*%d()")
  assert(vim.fn.getwininfo(winid)[1].textoff - (right_edge - 1) == 1,
    "console should have only one space between the line number and prompt")
  return right_edge
end
assert(
  number_right_edge(current_line) == number_right_edge(current_line - 1),
  "current line number is not aligned with the surrounding relative numbers"
)

-- Exercise real Insert/Normal transitions: Insert mode should reclaim the
-- entire gutter, while returning to Normal restores the compact numbers.
local normal_state = window_state()
local insert_state
vim.defer_fn(function()
  insert_state = window_state()
  insert_state.mode = vim.api.nvim_get_mode().mode
  vim.api.nvim_input(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
end, 100)
vim.api.nvim_feedkeys("i", "nx!", false)
assert(insert_state and insert_state.mode:sub(1, 1) == "i", "console did not enter Insert mode")
assert(insert_state.textoff == 0, "Insert mode should reclaim the entire line-number gutter")
assert(insert_state.gutter == "", "Insert mode should not leave numbers, padding, or a divider")
assert(insert_state.conceallevel == 2, "Insert mode should conceal prior output prefixes")

wait_for_window_state("terminal console normal mode restores line numbers and output prefixes", {
  numbers_visible = true,
  conceallevel = 0,
})
assert(window_state().textoff == normal_state.textoff, "Normal mode did not restore the compact gutter")

-- Visual selection in the terminal transcript should keep line numbers available.
vim.api.nvim_feedkeys("v", "nx", false)
wait_for_mode("terminal console enters visual mode", function(mode)
  return mode == "v" or mode == "V" or mode == "\22"
end)
wait_for_window_state("terminal console visual mode shows line numbers and output prefixes", {
  numbers_visible = true,
  conceallevel = 0,
})

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
wait_for_mode("terminal console exits visual mode", function(mode)
  return mode:sub(1, 1) == "n"
end)
wait_for_window_state("terminal console normal mode keeps line numbers and output prefixes", {
  numbers_visible = true,
  conceallevel = 0,
})

vim.print({
  nvim_console_line_numbers = "ok",
})

stop_watchdog()
