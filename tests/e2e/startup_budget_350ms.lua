local start_ms = vim.loop.hrtime() / 1e6
local marks = {}
local budget_ms = 350

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
    cache_ttl_ms = 50,
    throttle_ms = 25,
    timeout_ms = 25,
  })
end

local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype == "" then
  vim.cmd("setfiletype r")
end

local ok, ark = pcall(require, "ark")
if not ok then
  error("ark must be available for startup budget probe", 0)
end

-- This is the fastest repo-owned full startup shape we currently support:
-- start a managed pane and detached LSP together, then require the runtime to
-- be fully hydrated against the live session.
ark.setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = true,
  configure_slime = true,
})

local function await_mark(name, timeout_ms, predicate)
  local ready = vim.wait(timeout_ms, predicate, 10, false)
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

local startup_elapsed_ms = elapsed_ms()
if startup_elapsed_ms > budget_ms then
  error(vim.inspect({
    error = string.format("full startup exceeded %d ms budget: %.1f ms", budget_ms, startup_elapsed_ms),
    budget_ms = budget_ms,
    marks = marks,
    status = require("ark").status({ include_lsp = true }),
  }), 0)
end

vim.print({
  budget_ms = budget_ms,
  marks = marks,
  startup_elapsed_ms = startup_elapsed_ms,
  status = require("ark").status({ include_lsp = true }),
})
