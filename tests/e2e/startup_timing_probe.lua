local function ensure_bridge_runtime_current()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, err = bridge.ensure_current_runtime(config, {
    on_build_complete = function(result)
      completed = result
    end,
    user_initiated = true,
  })
  if ok then
    return
  end

  if type(err) ~= "table" or err.kind ~= "build_pending" then
    error("failed to prepare pane-side arkbridge runtime: " .. vim.inspect(err), 0)
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    error("timed out waiting for pane-side arkbridge runtime install: " .. vim.inspect(completed or err), 0)
  end

  local retry_ok, retry_err = bridge.ensure_current_runtime(config, {})
  if not retry_ok then
    error("pane-side arkbridge runtime was not current after install: " .. vim.inspect(retry_err), 0)
  end
end

ensure_bridge_runtime_current()

local start_ms = vim.loop.hrtime() / 1e6
local marks = {}

local function elapsed_ms()
  return (vim.loop.hrtime() / 1e6) - start_ms
end

local function mark(name)
  if marks[name] == nil then
    marks[name] = elapsed_ms()
  end
end

local function current_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
end

local function current_status()
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end

  return ark.status()
end

local function current_lsp_status(bufnr)
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end

  local ok_lsp, lsp = pcall(require, "ark.lsp")
  if not ok_lsp then
    return nil
  end

  return lsp.status(ark.options(), bufnr, {
    cache_ttl_ms = 250,
    throttle_ms = 100,
    timeout_ms = 50,
  })
end

local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype == "" then
  vim.cmd("setfiletype r")
end

local ok, ark = pcall(require, "ark")
if not ok then
  error("ark must be available for startup timing probe", 0)
end

ark.setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = false,
  configure_slime = true,
})

local function await_mark(name, timeout_ms, predicate)
  local ready = vim.wait(timeout_ms, predicate, 20, false)
  if not ready then
    error("timed out waiting for " .. name, 0)
  end

  mark(name)
end

await_mark("bridge_ready", 10000, function()
  local status = current_status()
  return status ~= nil and status.bridge_ready == true
end)

await_mark("repl_ready", 10000, function()
  local status = current_status()
  return status ~= nil and status.repl_ready == true
end)

await_mark("lsp_client", 10000, function()
  local client = current_client(bufnr)
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

await_mark("lsp_hydrated", 10000, function()
  local lsp_status = current_lsp_status(bufnr)
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

vim.print({
  marks = marks,
  startup_elapsed_ms = elapsed_ms(),
  status = require("ark").status({ include_lsp = true }),
})
