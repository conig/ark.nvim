vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/bridge_runtime_install_recovers_fresh_lock")
local lib_path = vim.fs.normalize(run_tmpdir .. "/r-lib")
local stamp_path = vim.fs.normalize(lib_path .. "/.arkbridge-install.json")
local lock_path = vim.fs.normalize(lib_path .. "/00LOCK-arkbridge")

vim.fn.mkdir(lock_path, "p")

local output = vim.fn.system({
  "R",
  "--slave",
  "--no-restore",
  "--no-save",
  "--no-site-file",
  "--no-init-file",
  "-f",
  vim.fs.normalize(vim.fn.getcwd() .. "/scripts/ark-install-bridge.R"),
  "--args",
  vim.fs.normalize(vim.fn.getcwd() .. "/packages/arkbridge"),
  lib_path,
  stamp_path,
  "0",
  "2",
})

if vim.v.shell_error ~= 0 then
  error("expected arkbridge installer to recover from a fresh lock, got:\n" .. tostring(output), 0)
end

if vim.fn.isdirectory(lock_path) == 1 then
  error("expected arkbridge installer to remove the fresh lock", 0)
end

if vim.fn.isdirectory(lib_path .. "/arkbridge") ~= 1 then
  error("expected arkbridge package to be installed", 0)
end

if vim.fn.filereadable(stamp_path) ~= 1 then
  error("expected arkbridge install stamp to be written", 0)
end

vim.print({
  bridge_runtime_install_recovers_fresh_lock = "ok",
})
