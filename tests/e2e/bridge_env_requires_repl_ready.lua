vim.opt.rtp:prepend(vim.fn.getcwd())
package.path = package.path .. ";" .. vim.fn.getcwd() .. "/tests/e2e/?.lua"

local ark_test = require("ark_test")

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_bridge_env_requires_repl_ready.R"

vim.fn.writefile({
  "library(ggpl",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  ark_test.fail(pane_err or "managed pane id missing")
end

ark_test.wait_for("bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

local config_before_prompt = require("ark.lsp").config(require("ark").options(), 0)
local env_before_prompt = config_before_prompt.cmd_env or {}

if env_before_prompt.ARK_SESSION_STATUS_FILE == nil then
  ark_test.fail("session discovery env missing before repl_ready: " .. vim.inspect(config_before_prompt))
end

if env_before_prompt.ARK_SESSION_PORT ~= nil or env_before_prompt.ARK_SESSION_AUTH_TOKEN ~= nil then
  ark_test.fail("bridge env leaked live connection details before repl_ready: " .. vim.inspect(config_before_prompt))
end

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

local config_after_prompt = require("ark.lsp").config(require("ark").options(), 0)
local env_after_prompt = config_after_prompt.cmd_env or {}

if env_after_prompt.ARK_SESSION_STATUS_FILE == nil then
  ark_test.fail("session discovery env missing after repl_ready: " .. vim.inspect(config_after_prompt))
end

vim.print({
  pane_id = pane_id,
  cmd_env_before_prompt = env_before_prompt,
  cmd_env_after_prompt = env_after_prompt,
})
