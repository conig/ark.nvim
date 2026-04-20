local M = {}
local dev = require("ark.dev")
local session_backend = require("ark.session")
local uv = vim.uv or vim.loop

local SESSION_UPDATE_METHOD = "ark/updateSession"
local SESSION_BOOTSTRAP_METHOD = "ark/internal/bootstrapSession"
local HELP_TOPIC_METHOD = "ark/textDocument/helpTopic"
local HELP_TEXT_METHOD = "ark/internal/helpText"
local STATUS_REQUEST_METHOD = "ark/internal/status"
local VIEW_OPEN_METHOD = "ark/internal/viewOpen"
local VIEW_STATE_METHOD = "ark/internal/viewState"
local VIEW_PAGE_METHOD = "ark/internal/viewPage"
local VIEW_SORT_METHOD = "ark/internal/viewSort"
local VIEW_FILTER_METHOD = "ark/internal/viewFilter"
local VIEW_SCHEMA_SEARCH_METHOD = "ark/internal/viewSchemaSearch"
local VIEW_PROFILE_METHOD = "ark/internal/viewProfile"
local VIEW_CODE_METHOD = "ark/internal/viewCode"
local VIEW_EXPORT_METHOD = "ark/internal/viewExport"
local VIEW_CELL_METHOD = "ark/internal/viewCell"
local VIEW_CLOSE_METHOD = "ark/internal/viewClose"

local session_watches = {}
local buffer_watch_cleanup = {}
local buffer_watch_keys = {}
local client_session_payloads = {}
local client_status_payloads = {}
local client_status_attempt_ms = {}
local managed_client_ids = {}
local pending_startup_bootstraps = {}
local bootstrap_client_session
local session_watch_finished
local session_poll_finished
local startup_ready_callback = nil
local STATUS_CACHE_TTL_MS = 250
local STATUS_THROTTLE_MS = 100
local STARTUP_READY_SOURCES = {
  immediate = "LspBootstrapImmediate",
  poll = "LspBootstrapPoll",
  retry = "LspBootstrapRetry",
  watch = "LspBootstrapWatch",
}

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function resolve_bufnr(bufnr)
  if bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
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

local function client_name(client)
  return client and (client.name or (client.config and client.config.name))
end

local function client_attached(client, bufnr)
  if not client or type(client.id) ~= "number" then
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

local function client_matches(client, opts, bufnr, match_opts)
  match_opts = match_opts or {}
  if client_name(client) ~= opts.lsp.name then
    return false
  end

  if match_opts.require_live ~= false and not live_client(client) then
    return false
  end

  return client_attached(client, bufnr)
end

local function known_clients(opts, bufnr, match_opts)
  local clients = {}

  for client_id, _ in pairs(managed_client_ids) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client_name(client) ~= opts.lsp.name then
      forget_client_id(client_id)
    elseif client_matches(client, opts, bufnr, match_opts) then
      clients[#clients + 1] = client
    end
  end

  return clients
end

local function session_clients(opts, bufnr, match_opts)
  match_opts = match_opts or {}
  local clients = {}
  local seen = {}

  for _, client in ipairs(known_clients(opts, bufnr, match_opts)) do
    clients[#clients + 1] = client
    seen[client.id] = true
  end

  local filter = { name = opts.lsp.name }
  if match_opts.require_live == false then
    filter._uninitialized = true
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    filter.bufnr = bufnr
  end

  for _, client in ipairs(vim.lsp.get_clients(filter)) do
    if client_matches(client, opts, bufnr, match_opts) and not seen[client.id] then
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

local function named_clients(opts, bufnr)
  return session_clients(opts, bufnr, {
    require_live = false,
  })
end

local function clients_for_buffers(opts, bufnrs, match_opts)
  local clients = {}
  local seen = {}

  for _, bufnr in ipairs(bufnrs or {}) do
    for _, client in ipairs(session_clients(opts, bufnr, match_opts)) do
      if not seen[client.id] then
        clients[#clients + 1] = client
        seen[client.id] = true
      end
    end
  end

  return clients
end

local function wait_for_live_client(client_id, timeout_ms)
  if not client_id then
    return nil
  end

  if timeout_ms and timeout_ms > 0 then
    vim.wait(timeout_ms, function()
      return live_client(vim.lsp.get_client_by_id(client_id))
    end, 20, false)
  end

  local client = vim.lsp.get_client_by_id(client_id)
  if live_client(client) then
    return client
  end

  return nil
end

local function project_root_for_path(path, markers)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.root(path, markers or {})
end

local function unnamed_workspace_root()
  local state_root = vim.fn.stdpath("state")
  if type(state_root) ~= "string" or state_root == "" then
    state_root = (uv and uv.os_tmpdir and uv.os_tmpdir()) or "/tmp"
  end

  local scratch_root = vim.fs.normalize(state_root .. "/ark-unnamed-workspace")
  if vim.fn.isdirectory(scratch_root) ~= 1 then
    pcall(vim.fn.mkdir, scratch_root, "p")
  end

  return scratch_root
end

local function home_directory()
  local env_home = vim.env.HOME
  if type(env_home) == "string" and env_home ~= "" then
    return vim.fs.normalize(env_home)
  end

  local homedir = uv and type(uv.os_homedir) == "function" and uv.os_homedir() or nil
  if type(homedir) == "string" and homedir ~= "" then
    return vim.fs.normalize(homedir)
  end

  return nil
end

local function root_dir(bufnr, markers)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cwd = vim.loop.cwd()
  if path == "" then
    return project_root_for_path(cwd, markers) or unnamed_workspace_root()
  end

  local root = project_root_for_path(path, markers)
  if root then
    return root
  end

  local path_dir = vim.fs.dirname(path)
  if type(path_dir) == "string" and path_dir ~= "" then
    local normalized_dir = vim.fs.normalize(path_dir)
    if normalized_dir == home_directory() then
      -- A direct `~/file.R` is usually an ad hoc scratch file, not a signal to
      -- index the whole home directory as one detached workspace.
      return unnamed_workspace_root()
    end

    return normalized_dir
  end

  return project_root_for_path(cwd, markers) or unnamed_workspace_root()
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

local function session_buffers(opts)
  local buffers = {}

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
      buffers[#buffers + 1] = bufnr
    end
  end

  return buffers
end

local function watch_has_buffers(watch)
  if type(watch) ~= "table" then
    return false
  end

  for bufnr, _ in pairs(watch.bufnrs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) and buffer_watch_keys[bufnr] == watch.key then
      return true
    end
  end

  return false
end

local function stop_session_watch(key)
  local watch = session_watches[key]
  if type(watch) ~= "table" then
    return
  end

  close_handle(watch.watcher)
  watch.watcher = nil
  watch.poll_token = nil

  for bufnr, _ in pairs(watch.bufnrs or {}) do
    if buffer_watch_keys[bufnr] == key then
      buffer_watch_keys[bufnr] = nil
    end
  end

  session_watches[key] = nil
end

local function detach_buffer_watch(bufnr)
  local key = buffer_watch_keys[bufnr]
  buffer_watch_keys[bufnr] = nil
  buffer_watch_cleanup[bufnr] = nil
  pending_startup_bootstraps[bufnr] = nil

  if type(key) ~= "string" or key == "" then
    return
  end

  local watch = session_watches[key]
  if type(watch) ~= "table" then
    return
  end

  watch.bufnrs[bufnr] = nil
  if not watch_has_buffers(watch) then
    stop_session_watch(key)
  end
end

local function attach_buffer_watch(status_path, bufnr)
  local current_key = buffer_watch_keys[bufnr]
  if current_key and current_key ~= status_path then
    detach_buffer_watch(bufnr)
  end

  local watch = session_watches[status_path]
  if type(watch) ~= "table" then
    watch = {
      key = status_path,
      bufnrs = {},
      watcher = nil,
      poll_token = nil,
    }
    session_watches[status_path] = watch
  end

  watch.bufnrs[bufnr] = true
  buffer_watch_keys[bufnr] = status_path
  return watch
end

local function ensure_session_watch_cleanup(bufnr)
  if buffer_watch_cleanup[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  buffer_watch_cleanup[bufnr] = true
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      detach_buffer_watch(bufnr)
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

local function keep_startup_bootstrap_pending(payload, hydrated)
  if hydrated == true or not payload_present(payload) then
    return false
  end

  return payload.status ~= "error"
end

local function startup_bootstrap_pending(bufnr)
  return type(bufnr) == "number" and pending_startup_bootstraps[bufnr] == true
end

local function set_startup_bootstrap_pending(bufnr, pending)
  if type(bufnr) ~= "number" then
    return
  end

  if pending then
    pending_startup_bootstraps[bufnr] = true
    return
  end

  pending_startup_bootstraps[bufnr] = nil
end

local function notify_startup_ready(bufnr, payload)
  if type(startup_ready_callback) ~= "function" then
    return
  end

  local ok, err = pcall(startup_ready_callback, bufnr, payload or {})
  if not ok then
    vim.schedule(function()
      vim.notify("ark.nvim startup ready callback failed: " .. tostring(err), vim.log.levels.WARN, {
        title = "ark.nvim",
      })
    end)
  end
end

local function session_snapshot(opts, snapshot_opts)
  snapshot_opts = snapshot_opts or {}
  if type(snapshot_opts.snapshot) == "table" then
    return snapshot_opts.snapshot
  end

  local snapshot = session_backend.startup_snapshot(opts, {
    include_prompt_ready = snapshot_opts.fast ~= true,
    validate_bridge = snapshot_opts.validate_bridge == true,
    bridge_timeout_ms = snapshot_opts.bridge_timeout_ms,
  })
  if type(snapshot) == "table" then
    return snapshot
  end

  local backend_status = nil
  if snapshot_opts.fast ~= true then
    backend_status = session_backend.status(opts)
  end
  local session = type(backend_status) == "table" and backend_status.session or nil
  if type(session) ~= "table" then
    session = session_backend.session(opts)
  end
  if type(session) ~= "table" then
    return nil
  end

  local status_path = type(backend_status) == "table" and backend_status.startup_status_path or nil
  if type(status_path) ~= "string" or status_path == "" then
    status_path = session_backend.startup_status_path(opts)
  end
  if type(status_path) ~= "string" or status_path == "" then
    return nil
  end

  local startup_status = type(backend_status) == "table" and backend_status.startup_status or nil
  if snapshot_opts.fast ~= true and type(startup_status) ~= "table" then
    startup_status = session_backend.startup_status(opts)
  end

  local authoritative_status = session_backend.startup_status_authoritative(opts)
  if type(authoritative_status) ~= "table" then
    authoritative_status = startup_status
  end

  return {
    bridge_ready = type(backend_status) == "table" and backend_status.bridge_ready == true or false,
    session = session,
    startup_status = startup_status,
    authoritative_status = authoritative_status,
    status_path = status_path,
    cmd_env = session_backend.bridge_env(opts) or nil,
  }
end

local function session_payload(opts, payload_opts)
  local snapshot = session_snapshot(opts, payload_opts)
  if type(snapshot) ~= "table" then
    return {}
  end

  local session = snapshot.session
  local runtime_config = session_backend.runtime_config(opts) or {}
  local session_id = session_backend.session_id(opts, session)
  local session_opts = type(opts.session) == "table" and opts.session or {}
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
    kind = session_opts.kind or (opts.tmux and opts.tmux.session_kind) or "ark",
    backend = session_backend.backend_name(opts),
    sessionId = session_id,
    statusFile = snapshot.status_path,
    tmuxSocket = session.tmux_socket,
    tmuxSession = session.tmux_session,
    tmuxPane = session.tmux_pane,
    timeoutMs = tonumber(runtime_config.session_timeout_ms or 1000) or 1000,
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

local function notify_watch_sessions(opts, watch, payload)
  if type(watch) ~= "table" then
    return
  end

  local bufnrs = {}
  for bufnr, _ in pairs(watch.bufnrs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) and buffer_watch_keys[bufnr] == watch.key then
      bufnrs[#bufnrs + 1] = bufnr
    end
  end

  local clients = clients_for_buffers(opts, bufnrs)
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

local function watch_payload_delivered(opts, watch, payload)
  if type(watch) ~= "table" then
    return false
  end

  local bufnrs = {}
  for bufnr, _ in pairs(watch.bufnrs or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) and buffer_watch_keys[bufnr] == watch.key then
      bufnrs[#bufnrs + 1] = bufnr
    end
  end

  local clients = clients_for_buffers(opts, bufnrs)
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

local function bootstrap_pending_startups(opts, watch, payload, source)
  if type(watch) ~= "table" or type(payload) ~= "table" then
    return
  end
  if payload.status ~= "ready" or payload.replReady ~= true then
    return
  end

  for bufnr, _ in pairs(watch.bufnrs or {}) do
    if not startup_bootstrap_pending(bufnr) then
      goto continue
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or buffer_watch_keys[bufnr] ~= watch.key then
      set_startup_bootstrap_pending(bufnr, false)
      goto continue
    end

    local client = session_clients(opts, bufnr)[1]
    if not live_client(client) then
      goto continue
    end

    local hydrated, bootstrap_err = bootstrap_client_session(client, opts, bufnr, payload)
    if bootstrap_err then
      vim.notify("ark.nvim session bootstrap failed: " .. bootstrap_err, vim.log.levels.WARN, {
        title = "ark.nvim",
      })
      goto continue
    end
    if not hydrated then
      goto continue
    end

    cache_client_session(client, payload)
    set_startup_bootstrap_pending(bufnr, false)
    notify_startup_ready(bufnr, {
      source = source or STARTUP_READY_SOURCES.watch,
    })

    ::continue::
  end
end

local function schedule_session_syncs(opts, bufnr, client_id)
  if not client_id then
    return
  end

  local delays = { 0, 250, 1000, 2000, 4000, 8000 }

  local function attempt(index)
    local client = vim.lsp.get_client_by_id(client_id)
    if not client or (client.is_stopped and client:is_stopped()) then
      return
    end

    local payload = session_payload(opts, { fast = true })
    if live_client(client) then
      notify_client_session(client, payload)

      if startup_bootstrap_pending(bufnr) and payload.status == "ready" and payload.replReady == true then
        local hydrated, bootstrap_err = bootstrap_client_session(client, opts, bufnr, payload)
        if bootstrap_err then
          vim.notify("ark.nvim session bootstrap failed: " .. bootstrap_err, vim.log.levels.WARN, {
            title = "ark.nvim",
          })
        elseif hydrated then
          cache_client_session(client, payload)
          set_startup_bootstrap_pending(bufnr, false)
          notify_startup_ready(bufnr, {
            source = STARTUP_READY_SOURCES.retry,
          })
        end
      end
    end

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
  local runtime_config = session_backend.runtime_config(opts) or {}
  local timeout_ms = tonumber(runtime_config.bridge_wait_ms or nil)
    or tonumber(opts.lsp and opts.lsp.restart_wait_ms or nil)
    or 5000
  return math.max(timeout_ms, 1000)
end

bootstrap_client_session = function(client, opts, bufnr, payload)
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

local function watch_poll_finished(opts, watch, payload)
  return payload.status == "ready" and watch_payload_delivered(opts, watch, payload)
end

local function ensure_session_watch(opts, bufnr, payload, watch_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  watch_opts = watch_opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    detach_buffer_watch(bufnr)
    return nil
  end
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    detach_buffer_watch(bufnr)
    return nil
  end

  local current_payload = payload or session_payload(opts, { fast = true })
  local status_path = current_payload.statusFile
  if type(status_path) ~= "string" or status_path == "" then
    detach_buffer_watch(bufnr)
    return nil
  end

  local watch = attach_buffer_watch(status_path, bufnr)
  ensure_session_watch_cleanup(bufnr)

  if watch_opts.notify_immediately ~= false then
    notify_watch_sessions(opts, watch, current_payload)
  end

  if session_watch_finished(opts, bufnr, current_payload) then
    stop_session_watch(watch.key)
    return watch
  end

  if not watch.watcher then
    local watch_key = watch.key
    local watcher = watch_status_file(status_path, function()
      local current_watch = session_watches[watch_key]
      if type(current_watch) ~= "table" then
        return
      end

      local current = session_payload(opts, { fast = true })
      if current.statusFile ~= watch_key then
        stop_session_watch(watch_key)
        return
      end

      notify_watch_sessions(opts, current_watch, current)
      bootstrap_pending_startups(opts, current_watch, current, STARTUP_READY_SOURCES.watch)
      if session_watch_finished(opts, nil, current) then
        stop_session_watch(watch_key)
      elseif watch_poll_finished(opts, current_watch, current) then
        current_watch.poll_token = nil
      end
    end)
    if watcher then
      watch.watcher = watcher
    end
  end

  if watch.watcher then
    return watch
  end

  if watch.poll_token ~= nil then
    return watch
  end

  local token = (tonumber(watch.poll_token) or 0) + 1
  watch.poll_token = token

  local function poll()
    local current_watch = session_watches[status_path]
    if type(current_watch) ~= "table" or current_watch.poll_token ~= token then
      return
    end

    local current = session_payload(opts, { fast = true })
    if current.statusFile ~= status_path then
      stop_session_watch(status_path)
      return
    end

    notify_watch_sessions(opts, current_watch, current)
    bootstrap_pending_startups(opts, current_watch, current, STARTUP_READY_SOURCES.poll)
    if session_watch_finished(opts, nil, current) then
      stop_session_watch(status_path)
      return
    end
    if watch_poll_finished(opts, current_watch, current) then
      current_watch.poll_token = nil
      return
    end

    vim.defer_fn(poll, 250)
  end

  vim.defer_fn(poll, 250)
  return watch
end

function M.config(opts, bufnr, _config_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  local cmd, cmd_err = dev.ensure_current_detached_lsp_cmd(opts.lsp.cmd, _config_opts)
  if not cmd then
    return nil, cmd_err
  end

  local startup_snapshot = _config_opts and _config_opts.startup_snapshot or nil
  local defer_session_bootstrap = _config_opts and _config_opts.defer_session_bootstrap == true or false
  local cmd_env = nil
  if not defer_session_bootstrap then
    local config_snapshot = type(startup_snapshot) == "table"
      and startup_snapshot
      or session_snapshot(opts, {
        fast = true,
        validate_bridge = true,
      })
    cmd_env = type(config_snapshot) == "table" and config_snapshot.cmd_env or nil
  end

  return {
    _ark_lsp_build_fingerprint = dev.detached_lsp_build_fingerprint(cmd[1]),
    name = opts.lsp.name,
    cmd = cmd,
    -- LuaSnip-driven placeholder edits can leave Neovim's incremental
    -- changetracker out of sync with Ark, which surfaces bogus syntax
    -- diagnostics after an otherwise valid snippet expansion.
    flags = {
      allow_incremental_sync = false,
    },
    cmd_env = cmd_env,
    root_dir = root_dir(bufnr, opts.lsp.root_markers),
  }, nil
end

local function start_client(opts, bufnr, start_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return nil
  end

  local wait_for_client_sync = not (start_opts and start_opts.wait_for_client == false)
  local background_session_updates = not (start_opts and start_opts.background_session_updates == false)
  local startup_snapshot = wait_for_client_sync and session_snapshot(opts, {
    fast = true,
    validate_bridge = false,
  }) or nil
  local startup_payload = wait_for_client_sync and session_payload(opts, {
    fast = true,
    snapshot = startup_snapshot,
  }) or {}

  local desired, config_err = M.config(opts, bufnr, vim.tbl_extend("force", start_opts or {}, {
    defer_session_bootstrap = not wait_for_client_sync,
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
        if background_session_updates then
          ensure_session_watch(opts, bufnr)
          notify_sessions(opts, bufnr)
        end
        return client.id
      end

      local hydrated = false
      local bootstrap_err = nil
      if payload_present(startup_payload) then
        hydrated, bootstrap_err = bootstrap_client_session(client, opts, bufnr, startup_payload)
        if hydrated then
          cache_client_session(client, startup_payload)
          notify_startup_ready(bufnr, {
            source = STARTUP_READY_SOURCES.immediate,
          })
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
      set_startup_bootstrap_pending(bufnr, keep_startup_bootstrap_pending(startup_payload, hydrated))
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
    if background_session_updates then
      vim.defer_fn(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
          return
        end

        ensure_session_watch(opts, bufnr)
      end, 0)
      schedule_session_syncs(opts, bufnr, client_id)
    end
    return client_id
  end

  local client = wait_for_live_client(client_id, opts.lsp.restart_wait_ms)
  local hydrated = false
  local bootstrap_err = nil
  if payload_present(startup_payload) and live_client(client) then
    hydrated, bootstrap_err = bootstrap_client_session(client, opts, bufnr, startup_payload)
    if hydrated then
      cache_client_session(client, startup_payload)
      notify_startup_ready(bufnr, {
        source = STARTUP_READY_SOURCES.immediate,
      })
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
  set_startup_bootstrap_pending(bufnr, keep_startup_bootstrap_pending(startup_payload, hydrated))
  if hydrated ~= true and not live_client(client) then
    schedule_session_syncs(opts, bufnr, client_id)
  end
  return client_id
end

local function restart_client(opts, bufnr, start_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    stop_lsp_client(client)
    forget_client_id(client.id)
  end

  return start_client(opts, bufnr, start_opts)
end

function M.start(opts, bufnr, start_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  return start_client(opts, bufnr, start_opts)
end

function M.restart(opts, bufnr, start_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  return restart_client(opts, bufnr, start_opts)
end

function M.start_async(opts, bufnr)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  return start_client(opts, bufnr, {
    wait_for_client = false,
  })
end

function M.prewarm(opts, bufnr)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  return start_client(opts, bufnr, {
    wait_for_client = false,
    background_session_updates = false,
  })
end

function M.set_startup_ready_callback(callback)
  startup_ready_callback = callback
end

function M.sync_sessions(opts, bufnr, sync_opts)
  bufnr = resolve_bufnr(bufnr)
  local payload_opts = vim.tbl_extend("keep", sync_opts or {}, {
    fast = true,
  })
  local payload = session_payload(opts, payload_opts)

  if bufnr then
    ensure_session_watch(opts, bufnr, payload)
    return
  end

  local touched_watches = {}
  for _, buffer in ipairs(session_buffers(opts)) do
    local watch = ensure_session_watch(opts, buffer, payload)
    if type(watch) == "table" then
      touched_watches[watch.key] = watch
    end
  end

  for _, watch in pairs(touched_watches) do
    notify_watch_sessions(opts, watch, payload)
  end
end

function M.refresh(opts, bufnr)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    forget_client_id(client.id)
  end

  return start_client(opts, bufnr)
end

function M.status(opts, bufnr, status_opts)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  status_opts = status_opts or {}

  local current_filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil
  local filetype_supported = filetype_enabled(opts.filetypes, current_filetype)
  local all_named_clients = named_clients(opts)
  local buffer_named_clients = vim.api.nvim_buf_is_valid(bufnr) and named_clients(opts, bufnr) or {}
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
    local pending_client = false
    for _, named_client in ipairs(buffer_named_clients) do
      if named_client.initialized ~= true and not (named_client.is_stopped and named_client:is_stopped()) then
        pending_client = true
        break
      end
    end

    if not filetype_supported then
      reason = "current buffer filetype is not managed by ark.nvim"
    elseif #all_named_clients > 0 and #buffer_named_clients == 0 then
      reason = "ark_lsp exists, but is not attached to the current buffer"
    elseif pending_client then
      reason = "ark_lsp client is starting"
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

local function view_request(opts, bufnr, method, params, timeout_ms)
  bufnr = resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
  local client = live_clients(opts, bufnr)[1]
  if not live_client(client) then
    return nil, "ark_lsp client unavailable"
  end

  return request_result(client, method, params or {}, timeout_ms or 5000, bufnr)
end

function M.view_open(opts, bufnr, expr)
  return view_request(opts, bufnr, VIEW_OPEN_METHOD, {
    expr = expr,
  }, 5000)
end

function M.view_state(opts, bufnr, session_id)
  return view_request(opts, bufnr, VIEW_STATE_METHOD, {
    sessionId = session_id,
  }, 3000)
end

function M.view_page(opts, bufnr, session_id, offset, limit)
  return view_request(opts, bufnr, VIEW_PAGE_METHOD, {
    sessionId = session_id,
    offset = offset or 0,
    limit = limit or 200,
  }, 5000)
end

function M.view_sort(opts, bufnr, session_id, column_index, direction)
  return view_request(opts, bufnr, VIEW_SORT_METHOD, {
    sessionId = session_id,
    columnIndex = column_index,
    direction = direction,
  }, 5000)
end

function M.view_filter(opts, bufnr, session_id, column_index, query)
  return view_request(opts, bufnr, VIEW_FILTER_METHOD, {
    sessionId = session_id,
    columnIndex = column_index,
    query = query,
  }, 5000)
end

function M.view_schema_search(opts, bufnr, session_id, query)
  return view_request(opts, bufnr, VIEW_SCHEMA_SEARCH_METHOD, {
    sessionId = session_id,
    query = query,
  }, 3000)
end

function M.view_profile(opts, bufnr, session_id, column_index)
  return view_request(opts, bufnr, VIEW_PROFILE_METHOD, {
    sessionId = session_id,
    columnIndex = column_index,
  }, 5000)
end

function M.view_code(opts, bufnr, session_id)
  return view_request(opts, bufnr, VIEW_CODE_METHOD, {
    sessionId = session_id,
  }, 3000)
end

function M.view_export(opts, bufnr, session_id, format)
  return view_request(opts, bufnr, VIEW_EXPORT_METHOD, {
    sessionId = session_id,
    format = format or "tsv",
  }, 5000)
end

function M.view_cell(opts, bufnr, session_id, row_index, column_index)
  return view_request(opts, bufnr, VIEW_CELL_METHOD, {
    sessionId = session_id,
    rowIndex = row_index,
    columnIndex = column_index,
  }, 3000)
end

function M.view_close(opts, bufnr, session_id)
  return view_request(opts, bufnr, VIEW_CLOSE_METHOD, {
    sessionId = session_id,
  }, 3000)
end

return M
