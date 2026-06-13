vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_idle_status_quiet")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-idle-status")
vim.fn.writefile({
  "#!/usr/bin/env bash",
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

local function file_fingerprint(path)
  local stat = vim.uv.fs_stat(path)
  if type(stat) ~= "table" then
    return nil
  end

  local mtime = stat.mtime or {}
  return table.concat({
    tostring(stat.size or ""),
    tostring(mtime.sec or ""),
    tostring(mtime.nsec or ""),
  }, ":")
end

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start idle status console: " .. tostring(err))
end

ark_test.wait_for("idle status fake prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

local console_status = require("ark.console").status(bufnr)
local status_path = console_status.status_path
ark_test.wait_for("idle status file", 10000, function()
  local published = require("ark.session_runtime").read_status_file(status_path)
  return type(published) == "table"
    and published.nvim_console_running == true
    and published.nvim_console_session_id == console_status.session_id
end)

vim.wait(650, function()
  return false
end, 50, false)

-- Regression coverage for idle chatter: the nvim-console status publisher must
-- not touch the shared session status file when its payload has not changed.
local idle_fingerprint = file_fingerprint(status_path)
if not idle_fingerprint then
  ark_test.fail("idle status file missing before quiet-window check: " .. tostring(status_path))
end

local changed_while_idle = vim.wait(1300, function()
  local current = file_fingerprint(status_path)
  return current ~= nil and current ~= idle_fingerprint
end, 50, false)
if changed_while_idle then
  ark_test.fail("nvim-console rewrote its status file while idle: " .. vim.inspect({
    before = idle_fingerprint,
    after = file_fingerprint(status_path),
    status_path = status_path,
    status = require("ark.session_runtime").read_status_file(status_path),
  }))
end

local ok, send_err = require("ark.console").send_text(bufnr, "1 + 1")
if not ok then
  ark_test.fail("failed to send after idle status check: " .. tostring(send_err))
end

ark_test.wait_for("status changes after send", 10000, function()
  local current = file_fingerprint(status_path)
  local published = require("ark.session_runtime").read_status_file(status_path)
  return current ~= nil
    and current ~= idle_fingerprint
    and type(published) == "table"
    and published.nvim_console_last_send == "1 + 1"
end)

stop_watchdog()
