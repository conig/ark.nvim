vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("syntax on")

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_insert_output_visible")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-insert-output-visible")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  if [ \"$line\" = 'mtcars |>' ]; then",
  "    continue",
  "  fi",
  "  if [ \"$line\" = '  lm(data = _, formu' ]; then",
  "    printf '+   lm(data = _, formu\\n'",
  "    printf '> '",
  "    continue",
  "  fi",
  "  if [ \"$line\" = 'mtcars' ]; then",
  "    printf 'VISIBLE_AFTER_OPEN_REGION\\n'",
  "    printf '> '",
  "    continue",
  "  fi",
  "  printf 'saw: %s\\n' \"$line\"",
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

ark_test.wait_for("fake prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

local send_ok, send_err = require("ark.console").send_text(bufnr, "mtcars |>\n  lm(data = _, formu")
if not send_ok then
  ark_test.fail("failed to send incomplete input: " .. tostring(send_err))
end

ark_test.wait_for("continuation echo output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> +   lm(data = _, formu", 1, true) ~= nil
end)

send_ok, send_err = require("ark.console").send_text(bufnr, "mtcars")
if not send_ok then
  ark_test.fail("failed to send visible output probe: " .. tostring(send_err))
end

local visible_row = nil
ark_test.wait_for("visible output line", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    if line == "#> VISIBLE_AFTER_OPEN_REGION" then
      visible_row = row
      return true
    end
  end
  return false
end)

vim.api.nvim_exec_autocmds("InsertEnter", { buffer = bufnr })
ark_test.wait_for("terminal console insert-mode conceal state", 5000, function()
  return vim.wo[0].conceallevel == 2
end)

-- Regression: a prior incomplete R input leaves following transcript lines
-- inside an R syntax region. Insert-mode prefix hiding must not make the
-- payload cells of those output lines disappear.
local payload_col = #"#> " + 1
local payload_conceal = vim.fn.synconcealed(visible_row, payload_col)
if type(payload_conceal) == "table" and payload_conceal[1] ~= 0 then
  ark_test.fail("console output payload was concealed in insert mode: " .. vim.inspect({
    row = visible_row,
    line = vim.api.nvim_buf_get_lines(bufnr, visible_row - 1, visible_row, false)[1],
    payload_col = payload_col,
    concealed = payload_conceal,
    stack = vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name")
    end, vim.fn.synstack(visible_row, payload_col)),
  }))
end

stop_watchdog()
