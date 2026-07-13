local repo_root = vim.fs.normalize(vim.fn.getcwd())
local ark_test = dofile(vim.fs.normalize(repo_root .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_console_init_user_config")

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
  "  table.insert(_G.ark_test_console_init_events, 'autopairs:' .. tostring(opts.owner))",
  "end",
  "return M",
}, vim.fs.normalize(autopairs_lua_dir .. "/nvim-autopairs.lua"))

local blink_lua_dir = vim.fs.normalize(data_home .. "/nvim/lazy/blink.cmp/lua/blink")
vim.fn.mkdir(blink_lua_dir, "p")
vim.fn.writefile({
  "local M = { setup_calls = {} }",
  "local has_setup = false",
  "function M.setup(opts)",
  "  if has_setup then",
  "    return",
  "  end",
  "  has_setup = true",
  "  opts = opts or {}",
  "  table.insert(M.setup_calls, vim.deepcopy(opts))",
  "  M.config = opts",
  "  table.insert(_G.ark_test_console_init_events, 'blink:' .. tostring(opts.owner))",
  "end",
  "return M",
}, vim.fs.normalize(blink_lua_dir .. "/cmp.lua"))

local config_dir = vim.fs.normalize(run_tmpdir .. "/ark-repl")
vim.fn.mkdir(config_dir, "p")
vim.fn.writefile({
  "table.insert(_G.ark_test_console_init_events, 'personal:start')",
  "vim.g.ark_test_repl_config_loaded = true",
  "vim.g.ark_test_repl_config_dir = vim.g.ark_repl_config_dir",
  "vim.g.ark_test_personal_saw_console_defaults = vim.o.laststatus == 0 and vim.o.showtabline == 0",
  "vim.o.statusline = 'personal-console-statusline'",
  "require('nvim-autopairs').setup({ owner = 'personal' })",
  "require('blink.cmp').setup({ owner = 'personal' })",
  "table.insert(_G.ark_test_console_init_events, 'personal:end')",
}, vim.fs.normalize(config_dir .. "/init.lua"))

vim.env.XDG_DATA_HOME = data_home
vim.env.ARK_NVIM_REPL_CONFIG_DIR = config_dir
_G.ark_test_console_init_events = {}

dofile(vim.fs.normalize(repo_root .. "/scripts/ark-console-init.lua"))

local autopairs = require("nvim-autopairs")
if #autopairs.setup_calls ~= 1 or autopairs.setup_calls[1].owner ~= "personal" then
  ark_test.fail("personal nvim-autopairs setup was replaced or repeated: " .. vim.inspect(autopairs.setup_calls))
end

local blink = require("blink.cmp")
if #blink.setup_calls ~= 1 or blink.setup_calls[1].owner ~= "personal" then
  ark_test.fail("personal Blink setup was replaced or repeated: " .. vim.inspect(blink.setup_calls))
end

local expected_events = {
  "personal:start",
  "autopairs:personal",
  "blink:personal",
  "personal:end",
}
if not vim.deep_equal(_G.ark_test_console_init_events, expected_events) then
  ark_test.fail("unexpected personal config/plugin setup order: " .. vim.inspect(_G.ark_test_console_init_events))
end

if vim.g.ark_test_personal_saw_console_defaults ~= true or vim.o.statusline ~= "personal-console-statusline" then
  ark_test.fail("Ark console defaults were not applied before personal overrides")
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
