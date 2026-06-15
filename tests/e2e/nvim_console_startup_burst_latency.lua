vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_startup_burst_latency")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/startup-burst-r")
local line_count = tonumber(vim.env.ARK_CONSOLE_STARTUP_BURST_LINES) or 10000
local budget_ms = tonumber(vim.env.ARK_CONSOLE_STARTUP_BURST_BUDGET_MS) or 2000
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

local start_ms = vim.loop.hrtime() / 1e6
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

local elapsed_ms = (vim.loop.hrtime() / 1e6) - start_ms
if elapsed_ms > budget_ms then
  ark_test.fail("startup burst console activation exceeded budget: " .. vim.inspect({
    elapsed_ms = elapsed_ms,
    budget_ms = budget_ms,
    line_count = line_count,
  }))
end

stop_watchdog()
