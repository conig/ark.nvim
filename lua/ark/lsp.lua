local M = {}
local tmux = require("ark.tmux")
local uv = vim.uv or vim.loop

local bridge_poll_tokens = {}

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

local function now_ms()
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1e6)
  end

  return math.floor((vim.loop.hrtime() or 0) / 1e6)
end

local function next_bridge_poll_token(bufnr)
  local token = (bridge_poll_tokens[bufnr] or 0) + 1
  bridge_poll_tokens[bufnr] = token
  return token
end

local function bridge_poll_active(bufnr, token)
  return bridge_poll_tokens[bufnr] == token
end

local function stop_bridge_poll(bufnr)
  bridge_poll_tokens[bufnr] = nil
end

function M.config(opts, bufnr, config_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  return {
    name = opts.lsp.name,
    cmd = opts.lsp.cmd,
    cmd_env = tmux.bridge_env(opts.tmux, {
      wait = config_opts == nil or config_opts.wait_for_bridge ~= false,
    }),
    root_dir = root_dir(bufnr, opts.lsp.root_markers),
  }
end

local function start_client(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return nil
  end

  local desired = M.config(opts, bufnr, start_opts)
  for _, client in ipairs(live_clients(opts, bufnr)) do
    if same_config(client.config, desired) then
      stop_bridge_poll(bufnr)
      return client.id
    end
  end

  local client_id = vim.lsp.start(desired, { bufnr = bufnr })
  if start_opts and start_opts.wait_for_client == false then
    return client_id
  end

  return wait_for_client(client_id, opts.lsp.restart_wait_ms)
end

local function restart_client(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local desired = M.config(opts, bufnr, start_opts)
  for _, client in ipairs(live_clients(opts, bufnr)) do
    if same_config(client.config, desired) then
      stop_bridge_poll(bufnr)
      return client.id
    end
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    vim.lsp.stop_client(client.id)
  end

  local client_id = vim.lsp.start(desired, { bufnr = bufnr })
  if start_opts and start_opts.wait_for_client == false then
    return client_id
  end

  return wait_for_client(client_id, opts.lsp.restart_wait_ms)
end

local function refresh_when_bridge_ready(opts, bufnr, token, deadline_ms)
  if not bridge_poll_active(bufnr, token) then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    stop_bridge_poll(bufnr)
    return
  end
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    stop_bridge_poll(bufnr)
    return
  end

  local desired = M.config(opts, bufnr, { wait_for_bridge = false })
  if desired.cmd_env and desired.cmd_env.ARK_SESSION_PORT then
    restart_client(opts, bufnr, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
    stop_bridge_poll(bufnr)
    return
  end

  if now_ms() >= deadline_ms then
    stop_bridge_poll(bufnr)
    return
  end

  vim.defer_fn(function()
    refresh_when_bridge_ready(opts, bufnr, token, deadline_ms)
  end, 100)
end

function M.start(opts, bufnr, start_opts)
  return start_client(opts, bufnr, start_opts)
end

function M.restart(opts, bufnr, start_opts)
  return restart_client(opts, bufnr, start_opts)
end

function M.start_async(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local client_id = start_client(opts, bufnr, {
    wait_for_bridge = false,
    wait_for_client = false,
  })

  local token = next_bridge_poll_token(bufnr)
  local deadline_ms = now_ms() + math.max(tonumber(opts.tmux.bridge_wait_ms) or 0, 1000)
  vim.defer_fn(function()
    refresh_when_bridge_ready(opts, bufnr, token, deadline_ms)
  end, 50)

  return client_id
end

return M
