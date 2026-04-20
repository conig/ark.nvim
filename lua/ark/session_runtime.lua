local uv = vim.uv or vim.loop
local bitops = bit or bit32

local M = {}

local startup_status_cache = {}
local bridge_ping_cache = {}
local BRIDGE_PING_CACHE_TTL_MS = 100

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function mode_has(mode, mask)
  if type(mode) ~= "number" or not bitops or type(bitops.band) ~= "function" then
    return false
  end

  return bitops.band(mode, mask) ~= 0
end

local function session_key(session)
  if type(session) ~= "table" then
    return ""
  end

  local session_id = type(session.session_id) == "string" and session.session_id or ""
  if session_id ~= "" then
    return table.concat({
      type(session.backend) == "string" and session.backend or "",
      session_id,
    }, "::")
  end

  return table.concat({
    type(session.tmux_socket) == "string" and session.tmux_socket or "",
    type(session.tmux_session) == "string" and session.tmux_session or "",
    type(session.tmux_pane) == "string" and session.tmux_pane or "",
  }, "::")
end

local function same_session(lhs, rhs)
  if type(lhs) ~= "table" or type(rhs) ~= "table" then
    return false
  end

  local lhs_session_id = type(lhs.session_id) == "string" and lhs.session_id or ""
  local rhs_session_id = type(rhs.session_id) == "string" and rhs.session_id or ""
  if lhs_session_id ~= "" or rhs_session_id ~= "" then
    return lhs_session_id ~= ""
      and lhs_session_id == rhs_session_id
      and (lhs.backend or "") == (rhs.backend or "")
  end

  return lhs.tmux_socket == rhs.tmux_socket
    and lhs.tmux_session == rhs.tmux_session
    and lhs.tmux_pane == rhs.tmux_pane
end

function M.status_root(config)
  local root = config.startup_status_dir
  if type(root) ~= "string" or root == "" then
    root = vim.env.ARK_STATUS_DIR
  end
  if type(root) ~= "string" or root == "" then
    root = (vim.fn.stdpath("state") or "/tmp") .. "/ark-status"
  end
  return vim.fs.normalize(root)
end

function M.status_file_path(config, session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return nil
  end

  return vim.fs.normalize(M.status_root(config) .. "/" .. session_id .. ".json")
end

function M.status_file_trusted(path)
  if type(path) ~= "string" or path == "" or not uv or not uv.fs_stat then
    return false
  end

  local stat = uv.fs_stat(path)
  if type(stat) ~= "table" or stat.type ~= "file" then
    return false
  end

  if type(uv.os_getuid) == "function" and type(stat.uid) == "number" then
    local ok, uid = pcall(uv.os_getuid)
    if ok and type(uid) == "number" and uid ~= stat.uid then
      return false
    end
  end

  if mode_has(stat.mode, 0x12) then
    return false
  end

  return true
end

function M.read_status_file(path)
  local cached = type(path) == "string" and startup_status_cache[path] or nil
  local cached_payload = type(cached) == "table" and cached.payload or nil

  if not path or vim.fn.filereadable(path) ~= 1 then
    if type(cached_payload) == "table" then
      return vim.deepcopy(cached_payload)
    end
    startup_status_cache[path or ""] = nil
    return nil
  end
  if not M.status_file_trusted(path) then
    startup_status_cache[path] = nil
    return nil
  end

  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  if type(cached) == "table"
    and type(stat) == "table"
    and cached.size == stat.size
    and cached.mtime_sec == (stat.mtime and stat.mtime.sec or nil)
    and cached.mtime_nsec == (stat.mtime and stat.mtime.nsec or nil)
  then
    return vim.deepcopy(cached.payload)
  end

  local lines = vim.fn.readfile(path)
  if type(lines) ~= "table" or #lines == 0 then
    if type(cached_payload) == "table" then
      return vim.deepcopy(cached_payload)
    end
    startup_status_cache[path] = nil
    return nil
  end

  local ok, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(payload) ~= "table" then
    if type(cached_payload) == "table" then
      return vim.deepcopy(cached_payload)
    end
    startup_status_cache[path] = nil
    return nil
  end

  payload.port = tonumber(payload.port)
  payload.pid = tonumber(payload.pid)
  payload.ts = tonumber(payload.ts)
  payload.repl_ts = tonumber(payload.repl_ts)
  payload.repl_seq = tonumber(payload.repl_seq)
  payload.auth_token = type(payload.auth_token) == "string" and payload.auth_token or ""
  payload.bootstrap_path = type(payload.bootstrap_path) == "string" and payload.bootstrap_path or nil
  payload.repl_ready = payload.repl_ready == true or payload.repl_ready == 1
  payload.log_path = type(payload.log_path) == "string" and payload.log_path or nil
  payload._status_path = path
  startup_status_cache[path] = {
    size = type(stat) == "table" and stat.size or nil,
    mtime_sec = type(stat) == "table" and stat.mtime and stat.mtime.sec or nil,
    mtime_nsec = type(stat) == "table" and stat.mtime and stat.mtime.nsec or nil,
    payload = vim.deepcopy(payload),
  }
  return payload
end

function M.ping_bridge(session, status, timeout_ms)
  if not uv or not uv.new_tcp then
    return false
  end

  local port = tonumber(status and status.port)
  if not port then
    return false
  end

  local request = vim.json.encode({
    request_id = string.format("ark-ping-%d", math.floor((uv.hrtime and uv.hrtime() or 0) / 1e6)),
    auth_token = status.auth_token or "",
    command = "ping",
    session = {
      backend = type(session) == "table" and session.backend or "",
      session_id = type(session) == "table" and session.session_id or "",
      tmux_socket = type(session) == "table" and session.tmux_socket or "",
      tmux_session = type(session) == "table" and session.tmux_session or "",
      tmux_pane = type(session) == "table" and session.tmux_pane or "",
    },
  })

  local cache_key = table.concat({
    session_key(session),
    tostring(port),
    status.auth_token or "",
    tostring(status.ts or ""),
    tostring(status.repl_seq or ""),
  }, "::")
  local cached = bridge_ping_cache[cache_key]
  local cache_ttl_ms = tonumber(timeout_ms) and math.max(50, math.floor((tonumber(timeout_ms) or 0) / 2))
    or BRIDGE_PING_CACHE_TTL_MS
  if type(cached) == "table" and monotonic_ms() - (tonumber(cached.checked_ms) or 0) < cache_ttl_ms then
    return cached.result == true
  end

  local client = uv.new_tcp()
  if not client then
    return false
  end

  local chunks = {}
  local done = false
  local err_msg = nil
  local closed = false

  local function close_client()
    if closed then
      return
    end
    closed = true
    pcall(client.read_stop, client)
    pcall(client.close, client)
  end

  client:connect("127.0.0.1", port, function(connect_err)
    if connect_err then
      err_msg = tostring(connect_err)
      done = true
      close_client()
      return
    end

    client:read_start(function(read_err, chunk)
      if read_err then
        err_msg = tostring(read_err)
        done = true
        close_client()
        return
      end

      if chunk then
        chunks[#chunks + 1] = chunk
        return
      end

      done = true
      close_client()
    end)

    client:write(request .. "\n", function(write_err)
      if write_err then
        err_msg = tostring(write_err)
        done = true
        close_client()
        return
      end

      client:shutdown(function(shutdown_err)
        if shutdown_err then
          err_msg = tostring(shutdown_err)
          done = true
          close_client()
        end
      end)
    end)
  end)

  local ok = vim.wait(timeout_ms or 250, function()
    return done
  end, 10, false)

  if not ok or err_msg then
    close_client()
    bridge_ping_cache[cache_key] = {
      checked_ms = monotonic_ms(),
      result = false,
    }
    return false
  end

  local decoded_ok, payload = pcall(vim.json.decode, table.concat(chunks, ""))
  if not decoded_ok or type(payload) ~= "table" then
    bridge_ping_cache[cache_key] = {
      checked_ms = monotonic_ms(),
      result = false,
    }
    return false
  end
  if payload.status ~= "ok" then
    bridge_ping_cache[cache_key] = {
      checked_ms = monotonic_ms(),
      result = false,
    }
    return false
  end
  if payload.session and not same_session(session, payload.session) then
    bridge_ping_cache[cache_key] = {
      checked_ms = monotonic_ms(),
      result = false,
    }
    return false
  end

  bridge_ping_cache[cache_key] = {
    checked_ms = monotonic_ms(),
    result = true,
  }
  return true
end

return M
