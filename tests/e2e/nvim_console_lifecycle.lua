vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_lifecycle")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-lifecycle")
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

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start lifecycle console: " .. tostring(err))
end

ark_test.wait_for("lifecycle fake prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

local eof_ok, eof_err = require("ark.console").eof(bufnr)
if not eof_ok then
  ark_test.fail("failed to send EOF to lifecycle console: " .. tostring(eof_err))
end

ark_test.wait_for("lifecycle process exit", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == false and status.exit_code == 0
end)

local exited_status = require("ark.console").status(bufnr)
ark_test.wait_for("lifecycle status clears RPC socket after exit", 10000, function()
  local published = require("ark.session_runtime").read_status_file(exited_status.status_path)
  return type(published) == "table"
    and published.nvim_console_running == false
    and type(published.nvim_console_rpc_socket) ~= "string"
end)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
if not table.concat(lines, "\n"):find("#> %[ark console exited: 0%]") then
  ark_test.fail("expected lifecycle exit marker: " .. vim.inspect(lines))
end

local wipe_bufnr, wipe_err = ark.console()
if not wipe_bufnr then
  ark_test.fail("failed to start wipe lifecycle console: " .. tostring(wipe_err))
end

ark_test.wait_for("wipe lifecycle fake prompt", 10000, function()
  local status = require("ark.console").status(wipe_bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

local wipe_status = require("ark.console").status(wipe_bufnr)
local wipe_jobid = wipe_status.jobid
local wipe_status_path = wipe_status.status_path
local lifecycle_autocmds = vim.api.nvim_get_autocmds({
  buffer = wipe_bufnr,
  group = "ArkConsoleLifecycle" .. tostring(wipe_bufnr),
})
if #lifecycle_autocmds == 0 then
  ark_test.fail("wipe lifecycle console should register buffer cleanup autocmd")
end
vim.api.nvim_buf_delete(wipe_bufnr, { force = true })

if vim.api.nvim_buf_is_valid(wipe_bufnr) then
  ark_test.fail("wipe lifecycle buffer should be invalid immediately after deletion: " .. vim.inspect({
    status = require("ark.console").status(wipe_bufnr),
    published = require("ark.session_runtime").read_status_file(wipe_status_path),
  }))
end

local last_wipe_published = nil
local closes_published = vim.wait(10000, function()
  local published = require("ark.session_runtime").read_status_file(wipe_status_path)
  last_wipe_published = published
  return type(published) == "table"
    and published.nvim_console == false
    and published.nvim_console_running == false
    and type(published.nvim_console_rpc_socket) ~= "string"
end, 100, false)
if not closes_published then
  ark_test.fail("wipe lifecycle did not publish closed status: " .. vim.inspect({
    module_status = require("ark.console").status(wipe_bufnr),
    published = last_wipe_published,
    status_path = wipe_status_path,
  }))
end

ark_test.wait_for("wipe lifecycle stops job", 10000, function()
  return vim.fn.jobwait({ wipe_jobid }, 0)[1] ~= -1
end)

stop_watchdog()
