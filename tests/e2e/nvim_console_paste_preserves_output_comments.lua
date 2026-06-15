vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_paste_preserves_output_comments")

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
  "  if [[ \"$line\" == \\#* ]]; then",
  "    printf '> '",
  "  elif [[ \"$line\" == 'produce_output()' ]]; then",
  "    printf 'replay_call()\\n'",
  "    printf '> '",
  "  elif [[ \"$line\" == 'replay_call()' ]]; then",
  "    printf 'replayed-ok\\n'",
  "    printf '> '",
  "  else",
  "    printf 'executed: %s\\n' \"$line\"",
  "    printf '> '",
  "  fi",
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

local function fake_r_log_lines()
  if vim.fn.filereadable(fake_r_log) ~= 1 then
    return {}
  end
  return vim.fn.readfile(fake_r_log)
end

local function current_input_lines()
  local status = require("ark.console").status(bufnr)
  if type(status) ~= "table" then
    ark_test.fail("missing Ark console status")
  end
  return vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
end

local function set_empty_input()
  local status = require("ark.console").status(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "" })
  vim.api.nvim_win_set_cursor(winid, { status.input_start + 1, 0 })
end

ark_test.wait_for("console prompt ready", 5000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.prompt_state == "top-level"
end)

local status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "produce_output()" })
local ok, submit_err = require("ark.console").submit(bufnr)
if not ok then
  ark_test.fail("failed to submit output-producing input: " .. tostring(submit_err))
end

ark_test.wait_for("replay command appears as prior output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return vim.tbl_contains(lines, "#> replay_call()")
end)

stop_insert_mode()

local output_row
for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  if line == "#> replay_call()" then
    output_row = index
    break
  end
end
if type(output_row) ~= "number" then
  ark_test.fail("failed to locate replay output line")
end

-- Regression: output prefixes are visible in normal mode, so normal-mode put
-- should preserve the yanked comment marker instead of silently rewriting it.
vim.api.nvim_win_set_cursor(winid, { output_row, 0 })
vim.cmd("normal! yy")
if vim.fn.getreg('"'):gsub("\n+$", "") ~= "#> replay_call()" then
  ark_test.fail("expected yanked output register to include stored transcript prefix: " .. vim.inspect(vim.fn.getreg('"')))
end

set_empty_input()
feed("p")

ark_test.wait_for("normal-mode p from output preserves transcript prefix in input", 4000, function()
  return vim.inspect(current_input_lines()) == vim.inspect({ "#> replay_call()" })
end)

local before_comment_submit_count = #fake_r_log_lines()
feed("<CR>")

ark_test.wait_for("single pasted output comment reaches fake R", 5000, function()
  return #fake_r_log_lines() >= before_comment_submit_count + 1
end)
local single_comment_line = fake_r_log_lines()[before_comment_submit_count + 1]
if single_comment_line ~= "#> replay_call()" then
  ark_test.fail("single yanked output line should submit as a comment: " .. vim.inspect(fake_r_log_lines()))
end
vim.wait(200)
if table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find("#> replayed%-ok") then
  ark_test.fail("commented replay_call() should not execute")
end

local commented_block = {
  "#> corx(data = mtcars)",
  "#> --------------------------------------------------------------------------------------------",
  "#>          mpg     cyl    disp      hp",
  "#> mpg       -  -.85*** -.85*** -.78***",
  "#> Note. * p < 0.05; ** p < 0.01; *** p < 0.001",
}

set_empty_input()
local paste_ok = vim.paste(vim.list_extend(vim.deepcopy(commented_block), { "" }), -1)
if paste_ok ~= true then
  ark_test.fail("vim.paste() rejected Ark console commented block paste")
end

ark_test.wait_for("multi-line commented output paste remains commented in input", 4000, function()
  return vim.inspect(current_input_lines()) == vim.inspect(commented_block)
end)

local before_block_submit_count = #fake_r_log_lines()
local block_submit_ok, block_submit_err = require("ark.console").submit(bufnr)
if not block_submit_ok then
  ark_test.fail("failed to submit commented output block: " .. tostring(block_submit_err))
end

ark_test.wait_for("multi-line commented block reaches fake R", 5000, function()
  return #fake_r_log_lines() >= before_block_submit_count + #commented_block
end)

local log_lines = fake_r_log_lines()
for offset, expected in ipairs(commented_block) do
  local actual = log_lines[before_block_submit_count + offset]
  if actual ~= expected then
    ark_test.fail("commented output block line was rewritten before submit: " .. vim.inspect({
      offset = offset,
      expected = expected,
      actual = actual,
      log = log_lines,
    }))
  end
end

local transcript = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
if transcript:find("#> executed:", 1, true) then
  ark_test.fail("commented output block should not execute table text: " .. transcript)
end

vim.print({
  nvim_console_paste_preserves_output_comments = "ok",
})

stop_watchdog()
