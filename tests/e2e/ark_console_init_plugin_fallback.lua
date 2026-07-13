local repo_root = vim.fs.normalize(vim.fn.getcwd())
local ark_test = dofile(vim.fs.normalize(repo_root .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_console_init_plugin_fallback")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local data_home = vim.fs.normalize(run_tmpdir .. "/xdg-data")
local autopairs_lua_dir = vim.fs.normalize(data_home .. "/nvim/lazy/nvim-autopairs/lua")
vim.fn.mkdir(autopairs_lua_dir, "p")
vim.fn.writefile({
  "local M = { setup_calls = {} }",
  "function M.setup(opts)",
  "  opts = opts or {}",
  "  table.insert(M.setup_calls, vim.deepcopy(opts))",
  "  M.config = opts",
  "  table.insert(_G.ark_test_console_init_events, 'autopairs:fallback')",
  "end",
  "return M",
}, vim.fs.normalize(autopairs_lua_dir .. "/nvim-autopairs.lua"))

local blink_lua_dir = vim.fs.normalize(data_home .. "/nvim/lazy/blink.cmp/lua/blink")
vim.fn.mkdir(blink_lua_dir, "p")
vim.fn.writefile({
  "local M = { setup_calls = {} }",
  "function M.setup(opts)",
  "  opts = opts or {}",
  "  table.insert(M.setup_calls, vim.deepcopy(opts))",
  "  M.config = opts",
  "  table.insert(_G.ark_test_console_init_events, 'blink:fallback')",
  "end",
  "return M",
}, vim.fs.normalize(blink_lua_dir .. "/cmp.lua"))

local config_dir = vim.fs.normalize(run_tmpdir .. "/ark-repl")
vim.fn.mkdir(config_dir, "p")
vim.fn.writefile({
  "table.insert(_G.ark_test_console_init_events, 'personal')",
  "vim.g.ark_test_repl_config_loaded = true",
}, vim.fs.normalize(config_dir .. "/init.lua"))

vim.env.XDG_DATA_HOME = data_home
vim.env.ARK_NVIM_REPL_CONFIG_DIR = config_dir
_G.ark_test_console_init_events = {}

dofile(vim.fs.normalize(repo_root .. "/scripts/ark-console-init.lua"))

local expected_events = {
  "personal",
  "autopairs:fallback",
  "blink:fallback",
}
if not vim.deep_equal(_G.ark_test_console_init_events, expected_events) then
  ark_test.fail("unexpected fallback plugin setup order: " .. vim.inspect(_G.ark_test_console_init_events))
end

local autopairs = require("nvim-autopairs")
if #autopairs.setup_calls ~= 1 or next(autopairs.setup_calls[1]) ~= nil then
  ark_test.fail("Ark did not apply the nvim-autopairs fallback: " .. vim.inspect(autopairs.setup_calls))
end

local blink = require("blink.cmp")
local blink_opts = blink.setup_calls[1]
if #blink.setup_calls ~= 1
  or type(blink_opts) ~= "table"
  or type(blink_opts.fuzzy) ~= "table"
  or blink_opts.fuzzy.implementation ~= "lua"
then
  ark_test.fail("Ark did not apply the Blink fallback: " .. vim.inspect(blink.setup_calls))
end

vim.print({
  ark_console_init_plugin_fallback = "ok",
})

stop_watchdog()
