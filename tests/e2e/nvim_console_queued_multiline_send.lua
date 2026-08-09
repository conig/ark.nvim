vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_queued_multiline_send")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-queued-send")
local input_log = vim.fs.normalize(run_tmpdir .. "/input.log")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "log=" .. vim.fn.shellescape(input_log),
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf '%s\\n' \"$line\" >> \"$log\"",
  "  if [ \"$line\" = slow ]; then",
  "    sleep 2",
  "  fi",
  "  printf 'saw: %s\\n> ' \"$line\"",
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
  ark_test.fail("failed to start queued-send console: " .. tostring(err))
end

ark_test.wait_for("queued-send console prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

-- A second send can arrive from the console RPC while the first multiline
-- chunk is waiting for R's next prompt. It must queue behind every unsent line
-- instead of replacing the active submission.
local send_ok, send_err = require("ark.console").send_text(bufnr, "slow\nremaining")
if not send_ok then
  ark_test.fail("failed to send multiline probe: " .. tostring(send_err))
end

send_ok, send_err = require("ark.console").send_text(bufnr, [[message("queued")]])
if not send_ok then
  ark_test.fail("failed to queue second probe: " .. tostring(send_err))
end

ark_test.wait_for("queued send to finish in fake R", 10000, function()
  if vim.fn.filereadable(input_log) ~= 1 then
    return false
  end
  local status = require("ark.console").status(bufnr)
  local transcript = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  return #vim.fn.readfile(input_log) >= 2
    and type(status) == "table"
    and status.prompt_state == "top-level"
    and transcript:find([[#> saw: message("queued")]], 1, true) ~= nil
end)

local received = vim.fn.readfile(input_log)
if vim.inspect(received) ~= vim.inspect({ "slow", "remaining", [[message("queued")]] }) then
  ark_test.fail("queued multiline sends reached R out of order or lost input: " .. vim.inspect(received))
end

local ansi_ns = vim.api.nvim_get_namespaces().ArkConsoleAnsi
local transcript = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local message_row
for row, line in ipairs(transcript) do
  if line == [[#> saw: message("queued")]] then
    message_row = row - 1
    break
  end
end

local message_highlighted = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ansi_ns, { message_row, 0 }, { message_row, -1 }, {
  details = true,
})) do
  if mark[4].hl_group == "ArkConsoleOutputMessage" then
    message_highlighted = true
    break
  end
end
if not message_highlighted then
  ark_test.fail("queued message output lost its semantic highlight")
end

stop_watchdog()
