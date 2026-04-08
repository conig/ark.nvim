local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype == "" then
  vim.cmd("setfiletype r")
end

local ok, ark = pcall(require, "ark")
if not ok then
  error("ark must be available for lsp status cache test", 0)
end

ark.setup({
  auto_start_pane = false,
  auto_start_lsp = true,
  async_startup = false,
  configure_slime = false,
})

local ready = vim.wait(5000, function()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end, 20, false)

if not ready then
  error("timed out waiting for ark_lsp client", 0)
end

local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
if not client then
  error("ark_lsp client missing", 0)
end

local calls = 0
local orig_request_sync = client.request_sync

client.request_sync = function(self, method, params, timeout_ms, target_bufnr)
  if method == "ark/internal/status" then
    calls = calls + 1
    return {
      result = {
        consoleScopeCount = 1,
        consoleScopeSymbolCount = 2,
        libraryPathCount = 1,
        runtimeMode = "detached",
        sessionBridgeConfigured = true,
        detachedSessionStatus = {
          lastSessionUpdateStatus = "ready",
        },
      },
    }, nil
  end

  return orig_request_sync(self, method, params, timeout_ms, target_bufnr)
end

local first = ark.status({ include_lsp = true })
local second = ark.status({ include_lsp = true })

if calls ~= 1 then
  error(string.format("expected one status request, got %d", calls), 0)
end

if first.lsp_status.available ~= true or second.lsp_status.available ~= true then
  error("expected cached lsp status to remain available", 0)
end

vim.print({
  calls = calls,
  first = first.lsp_status,
  second = second.lsp_status,
})
