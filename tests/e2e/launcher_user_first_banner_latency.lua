vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(45000, "launcher_user_first_banner_latency")

if vim.fn.executable("R") ~= 1 or vim.fn.executable("Rscript") ~= 1 then
  ark_test.fail("R and Rscript are required for launcher_user_first_banner_latency")
end

local function normalize(path)
  return vim.fs.normalize(path)
end

local run_tmpdir = ark_test.run_tmpdir()
local package_src = normalize(run_tmpdir .. "/arkbridge-stub")
local session_lib = normalize(run_tmpdir .. "/r-lib")
local status_dir = normalize(run_tmpdir .. "/status")
local user_profile = normalize(run_tmpdir .. "/user.Rprofile")
local wrapper = normalize(run_tmpdir .. "/ark-r-launcher-wrapper.sh")
local launcher = normalize(vim.fn.getcwd() .. "/scripts/ark-r-launcher.sh")
local session_id = "first_banner_latency"

vim.fn.mkdir(package_src .. "/R", "p")
vim.fn.mkdir(session_lib, "p")
vim.fn.mkdir(status_dir, "p")

vim.fn.writefile({
  "Package: arkbridge",
  "Version: 0.0.0",
  "Title: Test Stub",
  "Description: Test stub for ark.nvim launcher startup timing.",
  "License: MIT",
  "Encoding: UTF-8",
}, package_src .. "/DESCRIPTION")
vim.fn.writefile({
  "export(start_ipc_service)",
}, package_src .. "/NAMESPACE")
vim.fn.writefile({
  "start_ipc_service <- function(...) {",
  "  Sys.sleep(1.2)",
  "  list(port = 43210L)",
  "}",
  ".ark_dispatch_ipc_request <- function(...) NULL",
  ".ark_resolve_eval_env <- function(...) .GlobalEnv",
}, package_src .. "/R/stub.R")

local install = vim.fn.system({
  "R",
  "CMD",
  "INSTALL",
  "-l",
  session_lib,
  package_src,
})
if vim.v.shell_error ~= 0 then
  ark_test.fail("failed to install arkbridge timing stub: " .. install)
end

vim.fn.writefile({
  ".First <- function() {",
  "  cat('ARK_USER_FIRST_BANNER\\n')",
  "  flush.console()",
  "}",
}, user_profile)

vim.fn.writefile({
  "#!/usr/bin/env sh",
  "R_PROFILE_USER=" .. vim.fn.shellescape(user_profile)
    .. " ARK_NVIM_SESSION_LIB=" .. vim.fn.shellescape(session_lib)
    .. " ARK_STATUS_DIR=" .. vim.fn.shellescape(status_dir)
    .. " ARK_SESSION_ID=" .. vim.fn.shellescape(session_id)
    .. " ARK_NVIM_R_ARGS='--quiet --no-save --no-restore'"
    .. " exec "
    .. vim.fn.shellescape(launcher),
}, wrapper)
vim.fn.setfperm(wrapper, "rwxr-xr-x")

local chunks = {}
local started_ms = vim.loop.hrtime() / 1e6
local jobid = vim.fn.jobstart({ wrapper }, {
  pty = true,
  on_stdout = function(_, data, _)
    chunks[#chunks + 1] = table.concat(data or {}, "\n")
  end,
  on_stderr = function(_, data, _)
    chunks[#chunks + 1] = table.concat(data or {}, "\n")
  end,
})
if type(jobid) ~= "number" or jobid <= 0 then
  ark_test.fail("failed to start launcher timing job")
end

local banner_elapsed_ms
ark_test.wait_for("user .First banner", 10000, function()
  if table.concat(chunks, "\n"):find("ARK_USER_FIRST_BANNER", 1, true) ~= nil then
    banner_elapsed_ms = (vim.loop.hrtime() / 1e6) - started_ms
    return true
  end
  return false
end)

if banner_elapsed_ms > 700 then
  pcall(vim.fn.jobstop, jobid)
  ark_test.fail("user .First banner waited for Ark bridge setup: " .. vim.inspect({
    banner_elapsed_ms = banner_elapsed_ms,
    output = table.concat(chunks, "\n"),
  }))
end

local status_path = normalize(status_dir .. "/" .. session_id .. ".json")
ark_test.wait_for("launcher bridge status", 10000, function()
  if vim.fn.filereadable(status_path) ~= 1 then
    return false
  end
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(status_path), "\n"))
  return type(decoded) == "table" and decoded.status == "ready"
end)

pcall(vim.fn.jobstop, jobid)
stop_watchdog()
