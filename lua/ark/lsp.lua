local M = {}
local tmux = require("ark.tmux")

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function live_client(client)
  return client and client.initialized and not (client.is_stopped and client:is_stopped())
end

local function live_clients(opts, bufnr)
  local clients = {}

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    if live_client(client) then
      clients[#clients + 1] = client
    end
  end

  return clients
end

local function wait_for_client(client_id, timeout_ms)
  if not client_id or not timeout_ms or timeout_ms <= 0 then
    return client_id
  end

  vim.wait(timeout_ms, function()
    return live_client(vim.lsp.get_client_by_id(client_id))
  end, 20, false)

  return client_id
end

local function root_dir(bufnr, markers)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return vim.loop.cwd()
  end

  local root = vim.fs.root(path, markers or {})
  return root or vim.fs.dirname(path) or vim.loop.cwd()
end

local function same_config(lhs, rhs)
  if type(lhs) ~= "table" or type(rhs) ~= "table" then
    return false
  end

  return lhs.name == rhs.name
    and vim.deep_equal(lhs.cmd, rhs.cmd)
    and vim.deep_equal(lhs.cmd_env or {}, rhs.cmd_env or {})
    and lhs.root_dir == rhs.root_dir
end

function M.config(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  return {
    name = opts.lsp.name,
    cmd = opts.lsp.cmd,
    cmd_env = tmux.bridge_env(opts.tmux),
    root_dir = root_dir(bufnr, opts.lsp.root_markers),
  }
end

function M.start(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return nil
  end

  local desired = M.config(opts, bufnr)
  for _, client in ipairs(live_clients(opts, bufnr)) do
    if same_config(client.config, desired) then
      return client.id
    end
  end

  local client_id = vim.lsp.start(desired, { bufnr = bufnr })
  return wait_for_client(client_id, opts.lsp.restart_wait_ms)
end

function M.restart(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local desired = M.config(opts, bufnr)
  for _, client in ipairs(live_clients(opts, bufnr)) do
    if same_config(client.config, desired) then
      return client.id
    end
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    vim.lsp.stop_client(client.id)
  end

  local client_id = vim.lsp.start(desired, { bufnr = bufnr })
  return wait_for_client(client_id, opts.lsp.restart_wait_ms)
end

return M
