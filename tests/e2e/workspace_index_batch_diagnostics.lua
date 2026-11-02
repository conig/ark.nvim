local ark_test = require("ark_test")
require("ark").setup({ auto_start_pane = false, auto_start_lsp = false })
local root = ark_test.run_tmpdir() .. "/workspace-index-batch-diagnostics"
vim.fn.mkdir(root .. "/R/results/figures/pipeline", "p")
vim.fn.writefile({ 'targets::tar_source("R")' }, root .. "/_targets.R")
local main = root .. "/R/results/figures/pipeline/make_forest_plot.R"
local helper = root .. "/R/results/figures/build_forest_plot.R"
vim.fn.writefile({
  "make_forest_plot <- function(plot_data) {",
  "  p <- build_forest_plot(plot_data)",
  "  ark_unknown_function(p)",
  "}",
}, main)
vim.cmd("edit " .. vim.fn.fnameescape(main))
vim.bo.filetype = "r"

-- Use real stdio LSP and an explicit batched watcher notification. Disabling
-- automatic watchers prevents extra notifications from hiding a stale result.
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false }
capabilities.window.workDoneProgress = true
local scan_finished = false
local id = assert(vim.lsp.start({
  name = "ark_index_batch_test",
  cmd = { vim.env.ARK_NVIM_LSP_BIN or (vim.fn.getcwd() .. "/target/debug/ark-lsp"), "--runtime-mode", "detached" },
  cmd_env = { ARK_SESSION_STATUS_FILE = "", ARK_SESSION_PORT = "0", ARK_SESSION_AUTH_TOKEN = "" },
  root_dir = root,
  capabilities = capabilities,
  handlers = {
    ["$/progress"] = function(err, params, ctx, config)
      if tostring(params.token):find("ark-workspace-index-", 1, true) and params.value.kind == "end" then
        scan_finished = true
      end
      return vim.lsp.handlers["$/progress"](err, params, ctx, config)
    end,
  },
}))
ark_test.wait_for("detached LSP", 10000, function()
  return vim.lsp.get_client_by_id(id).initialized
end)
local client = vim.lsp.get_client_by_id(id)
local function missing(name)
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    if diagnostic.message == "No symbol named '" .. name .. "' in scope." then
      return true
    end
  end
  return false
end
ark_test.wait_for("initial missing helper diagnostic", 10000, function()
  return missing("build_forest_plot") and missing("ark_unknown_function")
end)
-- Startup must finish first: its own refresh could mask a dropped watcher
-- refresh, so use completion evidence rather than an arbitrary settling sleep.
ark_test.wait_for("initial workspace scan and baseline metadata", 10000, function()
  local status = ark_test.request(client, "ark/internal/status", {}, 3000)
  local baseline = status and status.detachedBaselineStatus or {}
  return scan_finished and baseline.lastBootstrapSuccessMs ~= nil and not baseline.pending
end)

-- Regression: a targets project receives a burst of disk updates. A helper
-- indexed after the first bounded chunk must clear its earlier warning without
-- another edit, runtime hydration, or an LSP restart. Genuine unknowns stay.
local changes = {}
for index = 1, 260 do
  local path = root .. "/R/helper_" .. index .. ".R"
  vim.fn.writefile({ "helper_" .. index .. " <- function() 1" }, path)
  changes[#changes + 1] = { uri = vim.uri_from_fname(path), type = vim.lsp.protocol.FileChangeType.Created }
end
vim.fn.writefile({ "build_forest_plot <- function(plot_data) plot_data" }, helper)
changes[#changes + 1] = { uri = vim.uri_from_fname(helper), type = vim.lsp.protocol.FileChangeType.Created }
assert(client:notify("workspace/didChangeWatchedFiles", { changes = changes }))
ark_test.wait_for("helper enters workspace index", 10000, function()
  local symbols = ark_test.request(client, "workspace/symbol", { query = "build_forest_plot" }, 3000)
  return symbols and #symbols > 0
end)
ark_test.wait_for("indexed helper clears stale scope diagnostic", 5000, function()
  return not missing("build_forest_plot") and missing("ark_unknown_function")
end)
print("batched workspace indexing clears helper warning and preserves genuine unknowns")
client:stop(true)
