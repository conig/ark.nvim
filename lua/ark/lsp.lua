local M = {}
local tmux = require("ark.tmux")
local uv = vim.uv or vim.loop

local SESSION_UPDATE_METHOD = "ark/updateSession"

local session_watchers = {}
local session_watch_cleanup = {}
local session_watch_polls = {}
local client_session_payloads = {}
local managed_client_ids = {}

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function live_client(client)
  return client and client.initialized and not (client.is_stopped and client:is_stopped())
end

local function track_client_id(client_id)
  if type(client_id) ~= "number" then
    return
  end

  managed_client_ids[client_id] = true
end

local function forget_client_id(client_id)
  if type(client_id) ~= "number" then
    return
  end

  managed_client_ids[client_id] = nil
  client_session_payloads[client_id] = nil
end

local function client_matches(client, opts, bufnr)
  local client_name = client and (client.name or (client.config and client.config.name))
  if not live_client(client) or client_name ~= opts.lsp.name then
    return false
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return true
  end

  if type(vim.lsp.buf_is_attached) == "function" then
    return vim.lsp.buf_is_attached(bufnr, client.id)
  end

  return true
end

local function known_clients(opts, bufnr)
  local clients = {}

  for client_id, _ in pairs(managed_client_ids) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client_matches(client, opts, bufnr) then
      clients[#clients + 1] = client
    else
      forget_client_id(client_id)
    end
  end

  return clients
end

local function session_clients(opts, bufnr)
  local clients = {}
  local seen = {}

  for _, client in ipairs(known_clients(opts, bufnr)) do
    clients[#clients + 1] = client
    seen[client.id] = true
  end

  local filter = { name = opts.lsp.name }
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    filter.bufnr = bufnr
  end

  for _, client in ipairs(vim.lsp.get_clients(filter)) do
    if client_matches(client, opts, bufnr) and not seen[client.id] then
      clients[#clients + 1] = client
      seen[client.id] = true
      track_client_id(client.id)
    end
  end

  return clients
end

local function live_clients(opts, bufnr)
  return session_clients(opts, bufnr)
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

local function same_server(lhs, rhs)
  if type(lhs) ~= "table" or type(rhs) ~= "table" then
    return false
  end

  return lhs.name == rhs.name
    and vim.deep_equal(lhs.cmd, rhs.cmd)
    and lhs.root_dir == rhs.root_dir
end

local function close_handle(handle)
  if not handle then
    return
  end

  pcall(handle.stop, handle)
  pcall(handle.close, handle)
end

local function stop_session_watch(bufnr)
  close_handle(session_watchers[bufnr])
  session_watchers[bufnr] = nil
  session_watch_cleanup[bufnr] = nil
  session_watch_polls[bufnr] = nil
end

local function session_buffers(opts)
  local buffers = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
      buffers[#buffers + 1] = bufnr
    end
  end

  return buffers
end

local function ensure_session_watch_cleanup(bufnr)
  if session_watch_cleanup[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  session_watch_cleanup[bufnr] = true
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      stop_session_watch(bufnr)
    end,
  })
end

local function session_payload(opts)
  local session = tmux.session and tmux.session() or nil
  if type(session) ~= "table" then
    return {}
  end

  local status_path = tmux.startup_status_path and tmux.startup_status_path(opts.tmux) or nil
  if type(status_path) ~= "string" or status_path == "" then
    return {}
  end

  local startup_status = tmux.startup_status and tmux.startup_status(opts.tmux) or nil

  return {
    kind = opts.tmux.session_kind,
    statusFile = status_path,
    tmuxSocket = session.tmux_socket,
    tmuxSession = session.tmux_session,
    tmuxPane = session.tmux_pane,
    timeoutMs = tonumber(opts.tmux.session_timeout_ms or 1000) or 1000,
    status = type(startup_status) == "table" and startup_status.status or "",
    replReady = type(startup_status) == "table" and startup_status.repl_ready == true or false,
  }
end

local function notify_client_session(client, payload)
  if not live_client(client) then
    return
  end

  local normalized = payload or {}
  if vim.deep_equal(client_session_payloads[client.id] or {}, normalized) then
    return
  end

  client_session_payloads[client.id] = vim.deepcopy(normalized)
  client:notify(SESSION_UPDATE_METHOD, normalized)
end

local function notify_sessions(opts, bufnr, payload)
  local clients = session_clients(opts, bufnr)
  local normalized = payload or session_payload(opts)
  for _, client in ipairs(clients) do
    notify_client_session(client, normalized)
  end
end

local function schedule_session_sync(opts, bufnr, client_id)
  if not client_id then
    return
  end

  local remaining = 20

  local function attempt()
    local client = vim.lsp.get_client_by_id(client_id)
    if live_client(client) then
      notify_client_session(client, session_payload(opts))
      return
    end

    remaining = remaining - 1
    if remaining <= 0 then
      return
    end

    vim.defer_fn(attempt, 100)
  end

  vim.defer_fn(attempt, 0)
end

local function watch_status_file(status_path, on_change)
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

  return nil
end

local function session_watch_finished(payload)
  return next(payload) == nil or payload.replReady == true or payload.status == "error"
end

local function ensure_session_watch(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    stop_session_watch(bufnr)
    return
  end
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    stop_session_watch(bufnr)
    return
  end

  local payload = session_payload(opts)
  notify_sessions(opts, bufnr, payload)

  if session_watch_finished(payload) then
    stop_session_watch(bufnr)
    return
  end

  local status_path = payload.statusFile
  if type(status_path) ~= "string" or status_path == "" then
    stop_session_watch(bufnr)
    return
  end

  if not session_watchers[bufnr] then
    local watcher = watch_status_file(status_path, function()
      local current = session_payload(opts)
      notify_sessions(opts, bufnr, current)
      if session_watch_finished(current) then
        stop_session_watch(bufnr)
      end
    end)
    if watcher then
      session_watchers[bufnr] = watcher
    end
  end

  if session_watch_polls[bufnr] ~= nil then
    ensure_session_watch_cleanup(bufnr)
    return
  end

  local token = (session_watch_polls[bufnr] or 0) + 1
  session_watch_polls[bufnr] = token

  local function poll()
    if session_watch_polls[bufnr] ~= token then
      return
    end

    local current = session_payload(opts)
    notify_sessions(opts, bufnr, current)
    if session_watch_finished(current) then
      stop_session_watch(bufnr)
      return
    end

    vim.defer_fn(poll, 250)
  end

  vim.defer_fn(poll, 250)
  ensure_session_watch_cleanup(bufnr)
end

function M.config(opts, bufnr, _config_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  return {
    name = opts.lsp.name,
    cmd = opts.lsp.cmd,
    cmd_env = tmux.bridge_env(opts.tmux),
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
    if same_server(client.config, desired) then
      ensure_session_watch(opts, bufnr)
      notify_sessions(opts, bufnr)
      return client.id
    end
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    if live_client(client) and not same_server(client.config, desired) then
      vim.lsp.stop_client(client.id)
      forget_client_id(client.id)
    end
  end

  local client_id = vim.lsp.start(desired, { bufnr = bufnr })
  track_client_id(client_id)
  ensure_session_watch(opts, bufnr)

  if start_opts and start_opts.wait_for_client == false then
    schedule_session_sync(opts, bufnr, client_id)
    return client_id
  end

  client_id = wait_for_client(client_id, opts.lsp.restart_wait_ms)
  notify_sessions(opts, bufnr)
  return client_id
end

local function restart_client(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    vim.lsp.stop_client(client.id)
    forget_client_id(client.id)
  end

  return start_client(opts, bufnr, start_opts)
end

function M.start(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return start_client(opts, bufnr, start_opts)
end

function M.restart(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return restart_client(opts, bufnr, start_opts)
end

function M.start_async(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return start_client(opts, bufnr, {
    wait_for_client = false,
  })
end

function M.sync_sessions(opts, bufnr)
  if bufnr then
    ensure_session_watch(opts, bufnr)
    return
  end

  for _, buffer in ipairs(session_buffers(opts)) do
    ensure_session_watch(opts, buffer)
  end

  notify_sessions(opts, nil)
end

function M.refresh(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    forget_client_id(client.id)
  end

  return start_client(opts, bufnr)
end

return M
