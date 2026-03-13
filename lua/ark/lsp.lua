local M = {}
local tmux = require("ark.tmux")
local uv = vim.uv or vim.loop

local bridge_start_tokens = {}
local bridge_start_watchers = {}

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

local function close_handle(handle)
  if not handle then
    return
  end

  pcall(handle.stop, handle)
  pcall(handle.close, handle)
end

local function next_bridge_start_token(bufnr)
  close_handle(bridge_start_watchers[bufnr])
  bridge_start_watchers[bufnr] = nil

  local token = (bridge_start_tokens[bufnr] or 0) + 1
  bridge_start_tokens[bufnr] = token
  return token
end

local function bridge_start_active(bufnr, token)
  return bridge_start_tokens[bufnr] == token
end

local function stop_bridge_start(bufnr)
  bridge_start_tokens[bufnr] = nil
  close_handle(bridge_start_watchers[bufnr])
  bridge_start_watchers[bufnr] = nil
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
      stop_bridge_start(bufnr)
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
      stop_bridge_start(bufnr)
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

local function startup_transition(opts, bufnr, token, start_opts)
  if not bridge_start_active(bufnr, token) then
    return
  end

  stop_bridge_start(bufnr)

  restart_client(opts, bufnr, start_opts)
end

local function bridge_start_target(opts, bufnr)
  local desired = M.config(opts, bufnr, { wait_for_bridge = false })
  if desired.cmd_env and desired.cmd_env.ARK_SESSION_PORT then
    return "live"
  end

  local status = tmux.startup_status(opts.tmux)
  if status and status.status == "error" then
    return "static"
  end

  return nil
end

local function watch_bridge_status(status_path, on_change)
  if not uv or type(status_path) ~= "string" or status_path == "" then
    return nil
  end

  local watch_path = vim.fs.dirname(status_path)
  if type(watch_path) ~= "string" or watch_path == "" then
    return nil
  end

  vim.fn.mkdir(watch_path, "p")

  local scheduled = false
  local function trigger()
    if scheduled then
      return
    end

    scheduled = true
    vim.schedule(function()
      scheduled = false
      on_change()
    end)
  end

  if uv.new_fs_event then
    local watcher = uv.new_fs_event()
    if watcher then
      local ok = watcher:start(watch_path, {}, function()
        trigger()
      end)
      if ok then
        return watcher
      end
      close_handle(watcher)
    end
  end

  if uv.new_fs_poll then
    local watcher = uv.new_fs_poll()
    if watcher then
      local ok = watcher:start(watch_path, 100, function()
        trigger()
      end)
      if ok then
        return watcher
      end
      close_handle(watcher)
    end
  end

  return nil
end

local function start_when_bridge_ready(opts, bufnr, token, deadline_ms)
  if not bridge_start_active(bufnr, token) then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    stop_bridge_start(bufnr)
    return nil
  end
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    stop_bridge_start(bufnr)
    return nil
  end

  local target = bridge_start_target(opts, bufnr)
  if target == "live" then
    startup_transition(opts, bufnr, token, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
    return true
  end

  if target == "static" then
    startup_transition(opts, bufnr, token, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
    return true
  end

  if now_ms() >= deadline_ms then
    startup_transition(opts, bufnr, token, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
    return true
  end

  return false
end

function M.start(opts, bufnr, start_opts)
  return start_client(opts, bufnr, start_opts)
end

function M.restart(opts, bufnr, start_opts)
  return restart_client(opts, bufnr, start_opts)
end

function M.start_async(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return nil
  end

  local initial_target = bridge_start_target(opts, bufnr)
  if initial_target == "live" then
    return start_client(opts, bufnr, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
  end

  local status_path = tmux.startup_status_path and tmux.startup_status_path(opts.tmux) or nil
  if initial_target == "static" or not status_path then
    return start_client(opts, bufnr, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
  end

  local token = next_bridge_start_token(bufnr)
  local deadline_ms = now_ms() + math.max(tonumber(opts.tmux.bridge_wait_ms) or 0, 1000)
  if start_when_bridge_ready(opts, bufnr, token, deadline_ms) then
    return nil
  end

  local watcher
  watcher = watch_bridge_status(status_path, function()
    start_when_bridge_ready(opts, bufnr, token, deadline_ms)
  end)

  if not watcher then
    stop_bridge_start(bufnr)
    return start_client(opts, bufnr, {
      wait_for_bridge = false,
      wait_for_client = false,
    })
  end

  bridge_start_watchers[bufnr] = watcher

  vim.defer_fn(function()
    if start_when_bridge_ready(opts, bufnr, token, deadline_ms) then
      return
    end

    stop_bridge_start(bufnr)
  end, math.max(deadline_ms - now_ms(), 1))

  return nil
end

return M
