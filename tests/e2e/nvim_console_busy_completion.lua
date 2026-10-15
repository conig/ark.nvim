-- Real external R + console status + detached LSP: a long evaluation must not
-- spend the live-request deadline on every keystroke or recommend restarting R.
local test = require("ark_test")
local repo = vim.env.ARK_REPO_ROOT or vim.fn.getcwd()
local root = test.run_tmpdir() .. "/busy-project"
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "Package: busytest", "Version: 0.0.0" }, root .. "/DESCRIPTION")
vim.cmd.cd(root)
local ark = require("ark")
ark.setup({ auto_start_pane = false, auto_start_lsp = true, async_startup = false,
  terminal = { launcher = repo .. "/scripts/ark-r-launcher.sh", startup_status_dir = test.run_tmpdir() .. "/status", session_pkg_path = repo .. "/packages/arkbridge" } })
local buf = assert(ark.console())
local console = require("ark.console")
local runtime = require("ark.session_runtime")
local client
local function published()
  return runtime.read_status_file(console.status(buf).status_path) or {}
end
test.wait_for("hydrated console", 30000, function()
  client = vim.lsp.get_clients({ bufnr = buf, name = "ark_lsp" })[1]
  if not client or not client.initialized or published().repl_ready ~= true then return false end
  local response = client:request_sync("ark/internal/status", {}, 1000, buf)
  return response and response.result and response.result.detachedSessionStatus.lastBootstrapSuccessMs ~= vim.NIL
end)
assert(console.send_text(buf, "busy_completion_function <- function(x) x"))
test.wait_for("definition complete", 5000, function() return published().nvim_console_prompt_state == "top-level" end)
-- Measure steady busy behavior, not the preceding definition's asynchronous
-- metadata hydration (startup/session hydration has its own performance gate).
test.wait_for("definition metadata hydration", 10000, function()
  local response = client:request_sync("ark/internal/status", {}, 1000, buf)
  local status = response and response.result and response.result.detachedSessionStatus
  return status and status.lastBootstrapReplSeq == published().repl_seq
    and type(status.lastBootstrapDurationMs) == "number"
end)
assert(console.send_text(buf, "Sys.sleep(4)"))
assert(runtime.console_busy(published()), "real console did not publish trustworthy busy evidence")
local state = require("ark.product_state")
assert(state.derive({ startup_status = published(), managed = true }, { auto_start_pane = false }) == "live_busy")
local line = console.status(buf).input_start
vim.api.nvim_buf_set_lines(buf, line, -1, false, { "busy_completion_f" })
vim.wait(200, function() return false end, 200)
local t = vim.uv.hrtime()
local response = test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(buf), position = { line = line, character = 17 }, context = { triggerKind = 1 },
}, 2000)
local elapsed = (vim.uv.hrtime() - t) / 1e6
assert(elapsed < 250, "busy completion waited for R: " .. elapsed .. "ms")
assert(test.find_item(test.completion_items(response), "busy_completion_function"), "static completion was lost while R was busy")
local debug = test.request(client, "ark/internal/status", {}, 1000)
assert(debug.sessionBridge.runtime.consecutiveFailures == 0, "normal evaluation poisoned the bridge circuit")
test.wait_for("R returns", 10000, function() return published().nvim_console_prompt_state == "top-level" end)
assert(not runtime.console_busy(published()), "busy evidence survived the returning prompt")
assert(console.stop(buf))
print(string.format("busy completion %.2fms", elapsed))
