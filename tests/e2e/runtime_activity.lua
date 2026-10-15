-- Busy is evidence from the live console owner, not a failed ping or old prompt.
local runtime = require("ark.session_runtime")
local product = require("ark.product_state")
local status = {
  pane_exists = true,
  managed = true,
  bridge_ready = false,
  repl_ready = false,
  startup_status = {
    pid = vim.fn.getpid(), nvim_console = true, nvim_console_running = true,
    nvim_console_pid = vim.fn.getpid(), nvim_console_prompt_pid = vim.fn.getpid(),
    nvim_console_prompt_state = "busy",
  },
}
assert(product.derive(status, { auto_start_pane = false }) == "live_busy", "known busy R was misreported as static-only")
assert(product.activity(status).kind == "user_code")
assert(not product.describe("live_busy").action:find("restart", 1, true))
assert(runtime.console_busy(status.startup_status))
local original_tcp = vim.uv.new_tcp
vim.uv.new_tcp = function() error("busy status must not open a ping socket") end
assert(runtime.ping_bridge({}, vim.tbl_extend("force", status.startup_status, { port = 12345 }), 1000) == false)
vim.uv.new_tcp = original_tcp
status.startup_status.nvim_console_prompt_pid = 1
assert(not runtime.console_busy(status.startup_status), "old R identity must not suppress requests")
assert(product.activity(status).kind == "unresponsive")
status.startup_status.nvim_console_prompt_pid = vim.fn.getpid()
status.startup_status.nvim_console_running = false
assert(not runtime.console_busy(status.startup_status), "closed console must not suppress requests")
status.startup_status = {}
status.lsp_status = { sessionBridge = { runtime = { activeOperation = { operation = "view_values", ageMs = 120 } } } }
assert(product.activity(status).kind == "ark_request")
assert(product.derive(status, {}) == "live_busy")
status.lsp_status = nil
status.pane_exists = false
assert(product.activity(status).kind == "disconnected")
status = { bridge_ready = true, repl_ready = true }
assert(product.derive(status, {}) == "live_ready")
