vim.opt.rtp:prepend(vim.fn.getcwd())
package.path = package.path .. ";" .. vim.fn.getcwd() .. "/tests/e2e/?.lua"

local ark_test = require("ark_test")

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_stale_ready_status.R"

vim.fn.writefile({
  "library(ggpl",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  ark_test.fail(pane_err or "managed pane id missing")
end

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

local status = require("ark").status()
local startup_status_path = status.startup_status_path
if type(startup_status_path) ~= "string" or startup_status_path == "" then
  ark_test.fail("startup status path missing: " .. vim.inspect(status))
end

local original_lines = vim.fn.readfile(startup_status_path)
local stale_status = vim.tbl_extend("force", status.startup_status or {}, {
  status = "ready",
  port = 9,
  auth_token = "stale-test-token",
})

vim.fn.writefile({ vim.json.encode(stale_status) }, startup_status_path)

local stale_config = require("ark.lsp").config(require("ark").options(), 0, {
  wait_for_bridge = false,
})

vim.fn.writefile(original_lines, startup_status_path)

if stale_config.cmd_env ~= nil then
  ark_test.fail("stale ready status produced live bridge env: " .. vim.inspect(stale_config))
end

vim.print({
  stale_status_path = startup_status_path,
  pane_id = status.pane_id,
})
