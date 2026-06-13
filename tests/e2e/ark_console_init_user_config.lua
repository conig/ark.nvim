local repo_root = vim.fs.normalize(vim.fn.getcwd())
local ark_test = dofile(vim.fs.normalize(repo_root .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_console_init_user_config")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local data_home = vim.fs.normalize(run_tmpdir .. "/xdg-data")
local autopairs_lua_dir = vim.fs.normalize(data_home .. "/nvim/lazy/nvim-autopairs/lua")
vim.fn.mkdir(autopairs_lua_dir, "p")
vim.fn.writefile({
  "local M = {}",
  "function M.setup(opts)",
  "  vim.g.ark_test_autopairs_setup = vim.inspect(opts or {})",
  "end",
  "return M",
}, vim.fs.normalize(autopairs_lua_dir .. "/nvim-autopairs.lua"))

local config_dir = vim.fs.normalize(run_tmpdir .. "/ark-repl")
vim.fn.mkdir(config_dir, "p")
vim.fn.writefile({
  "vim.g.ark_test_repl_config_loaded = true",
  "vim.g.ark_test_repl_config_dir = vim.g.ark_repl_config_dir",
}, vim.fs.normalize(config_dir .. "/init.lua"))

vim.env.XDG_DATA_HOME = data_home
vim.env.ARK_NVIM_REPL_CONFIG_DIR = config_dir

dofile(vim.fs.normalize(repo_root .. "/scripts/ark-console-init.lua"))

if vim.g.ark_test_autopairs_setup ~= "{}" then
  ark_test.fail("ark-console init did not set up nvim-autopairs: " .. vim.inspect(vim.g.ark_test_autopairs_setup))
end

if vim.g.ark_test_repl_config_loaded ~= true then
  ark_test.fail("ark-console init did not source the Ark REPL user config")
end

if vim.g.ark_test_repl_config_dir ~= config_dir then
  ark_test.fail("unexpected Ark REPL config dir: " .. vim.inspect(vim.g.ark_test_repl_config_dir))
end

if not vim.tbl_contains(vim.opt.runtimepath:get(), config_dir) then
  ark_test.fail("Ark REPL config dir was not added to runtimepath: " .. vim.inspect(vim.opt.runtimepath:get()))
end

vim.print({
  ark_console_init_user_config = "ok",
})

stop_watchdog()
