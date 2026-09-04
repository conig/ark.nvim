vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_incremental_transcript")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/startup-burst-r")
local line_count = tonumber(vim.env.ARK_CONSOLE_STARTUP_BURST_LINES) or 2000
local payload = string.rep("x", 160)

vim.fn.writefile({
  "#!/usr/bin/env bash",
  "for i in $(seq 1 " .. tostring(line_count) .. "); do",
  "  printf 'startup-%04d " .. payload .. "\\n' \"$i\"",
  "done",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'saw: %s\\n' \"$line\"",
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
  ark_test.fail("failed to start startup burst console: " .. tostring(err))
end

local final_line = string.format("#> startup-%04d", line_count)
ark_test.wait_for("startup burst console prompt", 15000, function()
  local status = require("ark.console").status(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return type(status) == "table"
    and status.running == true
    and status.prompt_state == "top-level"
    and table.concat(lines, "\n"):find(final_line, 1, true) ~= nil
end)

-- Exercise edits and new PTY output after a substantial transcript already exists.
-- Instrument buffer reads to detect work proportional to historical output.
local console = require("ark.console")
local boundary = console.status(bufnr).input_start
local original = vim.api.nvim_buf_get_lines
local historical_reads = 0
vim.api.nvim_buf_get_lines = function(buffer, first, last, strict)
  if buffer == bufnr and first < boundary then
    historical_reads = historical_reads + math.max(0, math.min(last < 0 and boundary or last, boundary) - first)
  end
  return original(buffer, first, last, strict)
end
vim.api.nvim_buf_set_lines(bufnr, boundary, -1, false, { "small_command" })
assert(console.submit(bufnr))
ark_test.wait_for("new output", 4000, function()
  return table.concat(original(bufnr, boundary, -1, false), "\n"):find("#> saw: small_command", 1, true) ~= nil
end)
vim.api.nvim_buf_get_lines = original
assert(historical_reads == 0, "small edit/output reread " .. historical_reads .. " historical lines")
stop_watchdog()
