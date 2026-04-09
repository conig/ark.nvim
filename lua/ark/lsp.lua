local M = {}
local dev = require("ark.dev")
local tmux = require("ark.tmux")
local uv = vim.uv or vim.loop

local SESSION_UPDATE_METHOD = "ark/updateSession"
local SESSION_BOOTSTRAP_METHOD = "ark/internal/bootstrapSession"
local HELP_TOPIC_METHOD = "ark/textDocument/helpTopic"
local HELP_TEXT_METHOD = "ark/internal/helpText"
local STATUS_REQUEST_METHOD = "ark/internal/status"

local session_watchers = {}
local session_watch_cleanup = {}
local session_watch_polls = {}
local client_session_payloads = {}
local client_status_payloads = {}
local client_status_attempt_ms = {}
local managed_client_ids = {}
local session_watch_finished
local session_poll_finished
local STATUS_CACHE_TTL_MS = 250
local STATUS_THROTTLE_MS = 100

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function topic_char_at(text, index)
  if type(text) ~= "string" or index < 0 or index >= #text then
    return nil
  end

  return text:sub(index + 1, index + 1)
end

local function is_topic_char(ch)
  return type(ch) == "string" and ch:match("[A-Za-z0-9._:$]") ~= nil
end

local function lexical_help_topic(bufnr, position)
  if type(position) ~= "table" or type(position.line) ~= "number" or type(position.character) ~= "number" then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, position.line, position.line + 1, false)[1] or ""
  local anchor = nil

  if is_topic_char(topic_char_at(line, position.character)) then
    anchor = position.character
  elseif is_topic_char(topic_char_at(line, position.character - 1)) then
    anchor = position.character - 1
  end

  if anchor == nil then
    return nil
  end

  local start_col = anchor
  while is_topic_char(topic_char_at(line, start_col - 1)) do
    start_col = start_col - 1
  end

  local end_col = anchor
  while is_topic_char(topic_char_at(line, end_col + 1)) do
    end_col = end_col + 1
  end

  local candidate = line:sub(start_col + 1, end_col + 1)
  if candidate == "" then
    return nil
  end

  if candidate:match("^[A-Za-z.][A-Za-z0-9._]*$") then
    return candidate
  end

  if candidate:match("^[A-Za-z.][A-Za-z0-9._]*::[A-Za-z.][A-Za-z0-9._]*$") then
    return candidate
  end

  if candidate:match("^[A-Za-z.][A-Za-z0-9._]*:::[A-Za-z.][A-Za-z0-9._]*$") then
    return candidate
  end

  if candidate:match("^[A-Za-z.][A-Za-z0-9._]*%$[A-Za-z.][A-Za-z0-9._]*$") then
    return candidate
  end

  if candidate:match("^[A-Za-z.][A-Za-z0-9._]*::[A-Za-z.][A-Za-z0-9._]*%$[A-Za-z.][A-Za-z0-9._]*$") then
    return candidate
  end

  return nil
end

local function live_client(client)
  return client and client.initialized and not (client.is_stopped and client:is_stopped())
end

local function stop_lsp_client(client, force)
  if not client then
    return
  end

  if type(client.stop) == "function" then
    client:stop(force)
    return
  end

  if type(vim.lsp.stop_client) ~= "function" or type(client.id) ~= "number" then
    return
  end

  if force == nil then
    vim.lsp.stop_client(client.id)
    return
  end

  vim.lsp.stop_client(client.id, force)
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
  client_status_payloads[client_id] = nil
  client_status_attempt_ms[client_id] = nil
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
    and lhs._ark_lsp_build_fingerprint == rhs._ark_lsp_build_fingerprint
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

local function normalize_repl_ready(status)
  if type(status) ~= "table" then
    return nil
  end

  if status.repl_ready == nil then
    return nil
  end

  return status.repl_ready == true or status.repl_ready == 1
end

local function request_result(client, method, params, timeout_ms, bufnr)
  local response, err = client:request_sync(method, params, timeout_ms, bufnr or 0)
  if err then
    return nil, err
  end
  if not response then
    return nil, "no response"
  end
  if response.error then
    return nil, vim.inspect(response.error)
  end
  if response.err then
    return nil, vim.inspect(response.err)
  end

  return response.result, nil
end

local function cache_client_session(client, payload)
  if not client or type(client.id) ~= "number" then
    return
  end

  client_session_payloads[client.id] = vim.deepcopy(payload or {})
end

local function cache_client_status(client, payload)
  if not client or type(client.id) ~= "number" then
    return
  end

  client_status_payloads[client.id] = {
    updated_ms = monotonic_ms(),
    payload = vim.deepcopy(payload or {}),
  }
end

local function cached_client_status(client, ttl_ms)
  if not client or type(client.id) ~= "number" then
    return nil
  end

  local cached = client_status_payloads[client.id]
  if type(cached) ~= "table" then
    return nil
  end

  local updated_ms = tonumber(cached.updated_ms)
  if not updated_ms then
    return nil
  end

  if monotonic_ms() - updated_ms > (tonumber(ttl_ms) or STATUS_CACHE_TTL_MS) then
    return nil
  end

  return vim.deepcopy(cached.payload or {})
end

local function status_base_payload(bufnr, filetype_supported, current_filetype, all_named_clients, buffer_named_clients, all_clients, client_id)
  return {
    client_id = client_id,
    bufnr = bufnr,
    filetype = current_filetype,
    filetype_supported = filetype_supported,
    total_named_clients = #all_named_clients,
    buffer_named_clients = #buffer_named_clients,
    clients = all_clients,
  }
end

local function payload_present(payload)
  return type(payload) == "table" and next(payload) ~= nil
end

local function session_snapshot(opts, snapshot_opts)
  snapshot_opts = snapshot_opts or {}
  if type(snapshot_opts.snapshot) == "table" then
    return snapshot_opts.snapshot
  end

  if type(tmux.startup_snapshot) == "function" then
    local snapshot = tmux.startup_snapshot(opts.tmux, {
      include_prompt_ready = snapshot_opts.fast ~= true,
      validate_bridge = snapshot_opts.validate_bridge == true,
      bridge_timeout_ms = snapshot_opts.bridge_timeout_ms,
    })
    if type(snapshot) == "table" then
      return snapshot
    end
  end

  local tmux_status = nil
  if snapshot_opts.fast ~= true and tmux.status then
    tmux_status = tmux.status(opts.tmux)
  end
  local session = type(tmux_status) == "table" and tmux_status.session or nil
  if type(session) ~= "table" and type(tmux.session) == "function" then
    session = tmux.session()
  end
  if type(session) ~= "table" then
    return nil
  end

  local status_path = type(tmux_status) == "table" and tmux_status.startup_status_path or nil
  if (type(status_path) ~= "string" or status_path == "")
    and type(tmux.startup_status_path) == "function"
  then
    status_path = tmux.startup_status_path(opts.tmux)
  end
  if type(status_path) ~= "string" or status_path == "" then
    return nil
  end

  local startup_status = type(tmux_status) == "table" and tmux_status.startup_status or nil
  if snapshot_opts.fast ~= true
    and type(startup_status) ~= "table"
    and type(tmux.startup_status) == "function"
  then
    startup_status = tmux.startup_status(opts.tmux)
  end

  local authoritative_status = nil
  if type(tmux.startup_status_authoritative) == "function" then
    authoritative_status = tmux.startup_status_authoritative(opts.tmux)
  elseif type(tmux.startup_status) == "function" then
    authoritative_status = tmux.startup_status(opts.tmux)
  end

  return {
    bridge_ready = type(tmux_status) == "table" and tmux_status.bridge_ready == true or false,
    session = session,
    startup_status = startup_status,
    authoritative_status = authoritative_status,
    status_path = status_path,
    cmd_env = snapshot_opts.validate_bridge == true and tmux.bridge_env and tmux.bridge_env(opts.tmux) or nil,
  }
end

local function session_payload(opts, payload_opts)
  local snapshot = session_snapshot(opts, payload_opts)
  if type(snapshot) ~= "table" then
    return {}
  end

  local session = snapshot.session
  local startup_status = snapshot.startup_status
  local authoritative_status = snapshot.authoritative_status
  local status = snapshot.bridge_ready == true and "ready"
    or (type(authoritative_status) == "table" and authoritative_status.status)
    or (type(startup_status) == "table" and startup_status.status)
    or ""
  local repl_ready = normalize_repl_ready(authoritative_status)
  if repl_ready == nil then
    repl_ready = snapshot.bridge_ready == true and true or normalize_repl_ready(startup_status)
  end

  return {
    kind = opts.tmux.session_kind,
    statusFile = snapshot.status_path,
    tmuxSocket = session.tmux_socket,
    tmuxSession = session.tmux_session,
    tmuxPane = session.tmux_pane,
    timeoutMs = tonumber(opts.tmux.session_timeout_ms or 1000) or 1000,
    status = status,
    replReady = repl_ready == true,
    replSeq = (type(authoritative_status) == "table" and authoritative_status.repl_seq)
      or (type(startup_status) == "table" and startup_status.repl_seq)
      or nil,
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

  cache_client_session(client, normalized)
  client:notify(SESSION_UPDATE_METHOD, normalized)
end

local function notify_sessions(opts, bufnr, payload)
  local clients = session_clients(opts, bufnr)
  local normalized = payload or session_payload(opts, { fast = true })
  for _, client in ipairs(clients) do
    notify_client_session(client, normalized)
  end
end

local function session_payload_delivered(opts, bufnr, payload)
  local clients = session_clients(opts, bufnr)
  if #clients == 0 then
    return false
  end

  local normalized = payload or {}
  for _, client in ipairs(clients) do
    if not vim.deep_equal(client_session_payloads[client.id] or {}, normalized) then
      return false
    end
  end

  return true
end

local function schedule_session_syncs(opts, bufnr, client_id)
  if not client_id then
    return
  end

  local delays = { 0, 250, 1000, 2000, 4000, 8000 }

  local function attempt(index)
    local client = vim.lsp.get_client_by_id(client_id)
    if not live_client(client) then
      return
    end

    local payload = session_payload(opts, { fast = true })
    notify_client_session(client, payload)

    if session_watch_finished(opts, bufnr, payload) or session_poll_finished(opts, bufnr, payload) then
      return
    end

    local next_index = index + 1
    if next_index > #delays then
      return
    end

    vim.defer_fn(function()
      attempt(next_index)
    end, delays[next_index])
  end

  vim.defer_fn(function()
    attempt(1)
  end, delays[1])
end

local function bootstrap_timeout_ms(opts)
  local timeout_ms = tonumber(opts.tmux and opts.tmux.bridge_wait_ms or nil)
    or tonumber(opts.lsp and opts.lsp.restart_wait_ms or nil)
    or 5000
  return math.max(timeout_ms, 1000)
end

local function bootstrap_client_session(client, opts, bufnr, payload)
  if not live_client(client) then
    return false, "ark_lsp client unavailable"
  end
  if not payload_present(payload) then
    return false, "session payload unavailable"
  end

  local result, err = request_result(
    client,
    SESSION_BOOTSTRAP_METHOD,
    payload,
    bootstrap_timeout_ms(opts),
    bufnr
  )
  if err then
    return false, err
  end
  if type(result) ~= "table" then
    return false, "invalid bootstrap response"
  end

  return result.hydrated == true, nil
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

session_watch_finished = function(opts, bufnr, payload)
  if next(payload) == nil or payload.status == "error" then
    return true
  end

  return false
end

session_poll_finished = function(opts, bufnr, payload)
  return payload.status == "ready" and session_payload_delivered(opts, bufnr, payload)
end

local function ensure_session_watch(opts, bufnr, payload, watch_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  watch_opts = watch_opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    stop_session_watch(bufnr)
    return
  end
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    stop_session_watch(bufnr)
    return
  end

  local current_payload = payload or session_payload(opts, { fast = true })
  if watch_opts.notify_immediately ~= false then
    notify_sessions(opts, nil, current_payload)
  end

  if session_watch_finished(opts, bufnr, current_payload) then
    stop_session_watch(bufnr)
    return
  end

  local status_path = current_payload.statusFile
  if type(status_path) ~= "string" or status_path == "" then
    stop_session_watch(bufnr)
    return
  end

  if not session_watchers[bufnr] then
    local watcher = watch_status_file(status_path, function()
      local current = session_payload(opts, { fast = true })
      notify_sessions(opts, nil, current)
      if session_watch_finished(opts, bufnr, current) then
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

    local current = session_payload(opts, { fast = true })
    notify_sessions(opts, nil, current)
    if session_watch_finished(opts, bufnr, current) then
      stop_session_watch(bufnr)
      return
    end
    if session_poll_finished(opts, bufnr, current) then
      session_watch_polls[bufnr] = nil
      ensure_session_watch_cleanup(bufnr)
      return
    end

    vim.defer_fn(poll, 250)
  end

  vim.defer_fn(poll, 250)
  ensure_session_watch_cleanup(bufnr)
end

function M.config(opts, bufnr, _config_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cmd, cmd_err = dev.ensure_current_detached_lsp_cmd(opts.lsp.cmd, _config_opts)
  if not cmd then
    return nil, cmd_err
  end

  local startup_snapshot = _config_opts and _config_opts.startup_snapshot or nil

  return {
    _ark_lsp_build_fingerprint = dev.detached_lsp_build_fingerprint(cmd[1]),
    name = opts.lsp.name,
    cmd = cmd,
    cmd_env = type(startup_snapshot) == "table"
      and startup_snapshot.cmd_env
      or tmux.bridge_env(opts.tmux, startup_snapshot),
    root_dir = root_dir(bufnr, opts.lsp.root_markers),
  }, nil
end

local function start_client(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return nil
  end

  local wait_for_client_sync = not (start_opts and start_opts.wait_for_client == false)
  local startup_snapshot = wait_for_client_sync and session_snapshot(opts, {
    fast = true,
    validate_bridge = true,
  }) or nil
  local startup_payload = session_payload(opts, {
    fast = true,
    snapshot = startup_snapshot,
  })

  local desired, config_err = M.config(opts, bufnr, vim.tbl_extend("force", start_opts or {}, {
    startup_snapshot = startup_snapshot,
    on_build_complete = function(result)
      if type(result) ~= "table" or result.ok ~= true then
        return
      end

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
          return
        end

        start_client(opts, bufnr, start_opts)
      end)
    end,
  }))
  if not desired then
    if type(config_err) == "table" and config_err.kind == "build_pending" then
      return nil
    end
    vim.notify(config_err, vim.log.levels.ERROR, { title = "ark.nvim" })
    return nil
  end
  for _, client in ipairs(live_clients(opts, bufnr)) do
    if same_server(client.config, desired) then
      if not wait_for_client_sync then
        ensure_session_watch(opts, bufnr)
        notify_sessions(opts, bufnr)
        return client.id
      end

      local hydrated = false
      local bootstrap_err = nil
      if payload_present(startup_payload) then
        hydrated, bootstrap_err = bootstrap_client_session(client, opts, bufnr, startup_payload)
        if hydrated then
          cache_client_session(client, startup_payload)
        end
      end
      if bootstrap_err then
        vim.notify("ark.nvim session bootstrap failed: " .. bootstrap_err, vim.log.levels.WARN, {
          title = "ark.nvim",
        })
      end
      ensure_session_watch(opts, bufnr, startup_payload, {
        notify_immediately = hydrated ~= true,
      })
      return client.id
    end
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    if live_client(client) and not same_server(client.config, desired) then
      stop_lsp_client(client)
      forget_client_id(client.id)
    end
  end

  local client_id = vim.lsp.start(desired, { bufnr = bufnr })
  track_client_id(client_id)

  if not wait_for_client_sync then
    ensure_session_watch(opts, bufnr)
    schedule_session_syncs(opts, bufnr, client_id)
    return client_id
  end

  client_id = wait_for_client(client_id, opts.lsp.restart_wait_ms)
  local client = vim.lsp.get_client_by_id(client_id)
  local hydrated = false
  local bootstrap_err = nil
  if payload_present(startup_payload) then
    hydrated, bootstrap_err = bootstrap_client_session(client, opts, bufnr, startup_payload)
    if hydrated then
      cache_client_session(client, startup_payload)
    end
  end
  if bootstrap_err then
    vim.notify("ark.nvim session bootstrap failed: " .. bootstrap_err, vim.log.levels.WARN, {
      title = "ark.nvim",
    })
  end
  ensure_session_watch(opts, bufnr, startup_payload, {
    notify_immediately = hydrated ~= true,
  })
  return client_id
end

local function restart_client(opts, bufnr, start_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    stop_lsp_client(client)
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

function M.sync_sessions(opts, bufnr, sync_opts)
  local payload_opts = vim.tbl_extend("keep", sync_opts or {}, {
    fast = true,
  })
  local payload = session_payload(opts, payload_opts)

  if bufnr then
    ensure_session_watch(opts, bufnr, payload)
    return
  end

  for _, buffer in ipairs(session_buffers(opts)) do
    ensure_session_watch(opts, buffer, payload)
  end

  notify_sessions(opts, nil, payload)
end

function M.refresh(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    forget_client_id(client.id)
  end

  return start_client(opts, bufnr)
end

function M.status(opts, bufnr, status_opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  status_opts = status_opts or {}

  local current_filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil
  local filetype_supported = filetype_enabled(opts.filetypes, current_filetype)
  local all_named_clients = vim.lsp.get_clients({ name = opts.lsp.name })
  local buffer_named_clients = vim.api.nvim_buf_is_valid(bufnr) and vim.lsp.get_clients({
    bufnr = bufnr,
    name = opts.lsp.name,
  }) or {}
  local all_clients = vim.tbl_map(function(client)
    return {
      id = client.id,
      initialized = client.initialized == true,
      stopped = client.is_stopped and client:is_stopped() or false,
      attached_buffers = vim.tbl_keys(client.attached_buffers or {}),
    }
  end, all_named_clients)

  local client = live_clients(opts, bufnr)[1]
  if not live_client(client) then
    local reason = "ark_lsp client unavailable"
    if not filetype_supported then
      reason = "current buffer filetype is not managed by ark.nvim"
    elseif #all_named_clients > 0 and #buffer_named_clients == 0 then
      reason = "ark_lsp exists, but is not attached to the current buffer"
    elseif #all_named_clients > 0 then
      reason = "ark_lsp exists, but no live initialized client is available"
    end

    return {
      available = false,
      reason = reason,
      bufnr = bufnr,
      filetype = current_filetype,
      filetype_supported = filetype_supported,
      total_named_clients = #all_named_clients,
      buffer_named_clients = #buffer_named_clients,
      clients = all_clients,
    }
  end

  local base = status_base_payload(
    bufnr,
    filetype_supported,
    current_filetype,
    all_named_clients,
    buffer_named_clients,
    all_clients,
    client.id
  )
  local cache_ttl_ms = tonumber(status_opts.cache_ttl_ms or STATUS_CACHE_TTL_MS) or STATUS_CACHE_TTL_MS
  local throttle_ms = tonumber(status_opts.throttle_ms or STATUS_THROTTLE_MS) or STATUS_THROTTLE_MS
  local request_timeout_ms = tonumber(status_opts.timeout_ms or 200) or 200
  local cached = cached_client_status(client, cache_ttl_ms)
  if type(cached) == "table" and next(cached) ~= nil then
    return vim.tbl_extend("force", {
      available = true,
    }, base, cached)
  end

  local now_ms = monotonic_ms()
  local last_attempt_ms = tonumber(client_status_attempt_ms[client.id]) or 0
  if last_attempt_ms > 0 and (now_ms - last_attempt_ms) < throttle_ms then
    local stale = client_status_payloads[client.id]
    if type(stale) == "table" and type(stale.payload) == "table" and next(stale.payload) ~= nil then
      return vim.tbl_extend("force", {
        available = true,
        stale = true,
      }, base, vim.deepcopy(stale.payload))
    end

    return vim.tbl_extend("force", {
      available = false,
      reason = "status pending",
    }, base)
  end

  client_status_attempt_ms[client.id] = now_ms

  local response, err = client:request_sync(STATUS_REQUEST_METHOD, {}, request_timeout_ms, bufnr)
  if err then
    local stale = client_status_payloads[client.id]
    if type(stale) == "table" and type(stale.payload) == "table" and next(stale.payload) ~= nil then
      return vim.tbl_extend("force", {
        available = true,
        stale = true,
      }, base, vim.deepcopy(stale.payload))
    end

    return vim.tbl_extend("force", {
      available = false,
      reason = err,
    }, base)
  end

  if not response then
    local stale = client_status_payloads[client.id]
    if type(stale) == "table" and type(stale.payload) == "table" and next(stale.payload) ~= nil then
      return vim.tbl_extend("force", {
        available = true,
        stale = true,
      }, base, vim.deepcopy(stale.payload))
    end

    return vim.tbl_extend("force", {
      available = false,
      reason = "no response",
    }, base)
  end

  if response.error then
    local stale = client_status_payloads[client.id]
    if type(stale) == "table" and type(stale.payload) == "table" and next(stale.payload) ~= nil then
      return vim.tbl_extend("force", {
        available = true,
        stale = true,
      }, base, vim.deepcopy(stale.payload))
    end

    return vim.tbl_extend("force", {
      available = false,
      reason = vim.inspect(response.error),
    }, base)
  end

  cache_client_status(client, response.result or {})

  return vim.tbl_extend("force", {
    available = true,
  }, base, response.result or {})
end

function M.help_topic(opts, bufnr, position)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local current_filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil
  if not filetype_enabled(opts.filetypes, current_filetype) then
    return nil, "current buffer filetype is not managed by ark.nvim"
  end

  local client = live_clients(opts, bufnr)[1]
  if not live_client(client) then
    return nil, "ark_lsp client unavailable"
  end

  local text_document = vim.lsp.util.make_versioned_text_document_params
      and vim.lsp.util.make_versioned_text_document_params(bufnr)
    or vim.lsp.util.make_text_document_params(bufnr)

  local target_position = position
  if type(target_position) ~= "table" then
    local cursor = vim.api.nvim_win_get_cursor(0)
    target_position = {
      line = cursor[1] - 1,
      character = cursor[2],
    }
  end

  local function request_topic(request_position)
    local response, err = client:request_sync(HELP_TOPIC_METHOD, {
      textDocument = text_document,
      position = request_position,
    }, 1000, bufnr)

    if err then
      return nil, err
    end

    if not response then
      return nil, "no response"
    end

    if response.error then
      return nil, vim.inspect(response.error)
    end

    local result = response.result
    if type(result) ~= "table" or type(result.topic) ~= "string" or result.topic == "" then
      return nil, "no help topic found"
    end

    return result.topic, nil
  end

  local topic, err = request_topic(target_position)
  if topic then
    return topic, nil
  end

  local fallback_topic = lexical_help_topic(bufnr, target_position)
  if fallback_topic then
    return fallback_topic, nil
  end

  return nil, err
end

function M.help_text(opts, bufnr, topic)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local current_filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil
  if not filetype_enabled(opts.filetypes, current_filetype) then
    return nil, "current buffer filetype is not managed by ark.nvim"
  end

  if type(topic) ~= "string" or topic == "" then
    return nil, "missing help topic"
  end

  local client = live_clients(opts, bufnr)[1]
  if not live_client(client) then
    return nil, "ark_lsp client unavailable"
  end

  local response, err = client:request_sync(HELP_TEXT_METHOD, {
    topic = topic,
  }, 3000, bufnr)

  if err then
    return nil, err
  end

  if not response then
    return nil, "no response"
  end

  if response.error then
    return nil, vim.inspect(response.error)
  end

  local result = response.result
  if type(result) ~= "table" or type(result.text) ~= "string" or result.text == "" then
    return nil, "no help text found"
  end

  if not vim.islist(result.references) then
    result.references = {}
  end

  return result, nil
end

return M
