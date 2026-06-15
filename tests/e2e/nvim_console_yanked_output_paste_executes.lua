vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_yanked_output_paste_executes")

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
  "  if [[ \"$line\" == 'produce_output()' ]]; then",
  "    printf 'replay_call()\\n'",
  "  elif [[ \"$line\" == 'replay_call()' ]]; then",
  "    printf 'replayed-ok\\n'",
  "  else",
  "    printf 'saw: %s\\n' \"$line\"",
  "  fi",
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

-- Regression: this mirrors yanking a command-shaped line from earlier output,
-- pressing `p` on the active prompt, then Enter. The stored transcript line has
-- a real "#> " prefix, even when the UI conceals it in insert mode.
vim.api.nvim_win_set_cursor(winid, { output_row, 0 })
vim.cmd("normal! yy")
if vim.fn.getreg('"'):gsub("\n+$", "") ~= "#> replay_call()" then
  ark_test.fail("expected yanked output register to include stored transcript prefix: " .. vim.inspect(vim.fn.getreg('"')))
end

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "" })
vim.api.nvim_win_set_cursor(winid, { status.input_start + 1, 0 })
feed("p")

ark_test.wait_for("normal-mode p from output strips transcript prefix in input", 4000, function()
  local current_status = require("ark.console").status(bufnr)
  local input = vim.api.nvim_buf_get_lines(bufnr, current_status.input_start, -1, false)
  return vim.inspect(input) == vim.inspect({ "replay_call()" })
end)

feed("<CR>")

ark_test.wait_for("pasted output command reaches R after Enter", 5000, function()
  return fake_r_log_text():find("produce_output%(%).*replay_call%(%)") ~= nil
end)

ark_test.wait_for("pasted output command produces output", 5000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> replayed%-ok") ~= nil
end)

vim.print({
  nvim_console_yanked_output_paste_executes = "ok",
})

stop_watchdog()
