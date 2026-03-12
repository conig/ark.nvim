local uv = vim.uv or vim.loop
local bitops = bit or bit32

local M = {}

local state = _G.__ark_nvim_state
if type(state) ~= "table" then
  state = {
    managed = false,
    pane_id = nil,
    session = nil,
  }
end
_G.__ark_nvim_state = state

local function sync_compat_state()
  _G.__r_repl_state = {
    pane_id = state.pane_id,
    managed = state.managed,
  }
end

sync_compat_state()

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shellescape(value)
  return vim.fn.shellescape(tostring(value))
end

local function run_tmux(args)
  local escaped = {}
  for _, arg in ipairs(args) do
    table.insert(escaped, shellescape(arg))
  end

  local output = vim.fn.system("tmux " .. table.concat(escaped, " "))
  if vim.v.shell_error ~= 0 then
    return nil, trim(output)
  end

  return trim(output), nil
end

local function parse_percent(value)
  value = trim(value)
  if value == "" or value:sub(1, 1) == "-" then
    return nil
  end

  local pct = tonumber(value:match("(%d+)"))
  if not pct then
    return nil
  end

  if pct < 10 then
    pct = 10
  elseif pct > 90 then
    pct = 90
  end

  return tostring(pct)
end

local function pane_exists(pane_id)
  if not pane_id or pane_id == "" then
    return false
  end

  local out = run_tmux({ "list-panes", "-a", "-F", "#{pane_id}" })
  if not out then
    return false
  end

  for line in out:gmatch("[^\r\n]+") do
    if trim(line) == pane_id then
      return true
    end
  end

  return false
end

local function resolve_pane_percent(config)
  for _, key in ipairs(config.pane_width_env_keys or {}) do
    local from_format = run_tmux({ "display-message", "-p", "#{" .. key .. "}" })
    local pct = parse_percent(from_format)
    if pct then
      return pct
    end

    local env_out = run_tmux({ "show-environment", "-g", key })
    if env_out then
      local raw_value = env_out:match("^[^=]+=([^\r\n]+)$")
      pct = parse_percent(raw_value)
      if pct then
        return pct
      end
    end
  end

  return tostring(config.pane_percent)
end

local function current_session(pane_id)
  local socket_path, socket_err = run_tmux({ "display-message", "-p", "#{socket_path}" })
  if not socket_path then
    return nil, "failed to get tmux socket path: " .. tostring(socket_err or "unknown")
  end

  local session_name, session_err = run_tmux({ "display-message", "-p", "#{session_name}" })
  if not session_name then
    return nil, "failed to get tmux session name: " .. tostring(session_err or "unknown")
  end

  return {
    tmux_socket = socket_path,
    tmux_session = session_name,
    tmux_pane = pane_id or state.pane_id,
  }, nil
end

local function configure_slime_target(pane_id)
  local session, err = current_session(pane_id)
  if not session then
    return nil, err
  end

  vim.g.slime_target = "tmux"
  vim.g.slime_default_config = {
    socket_name = session.tmux_socket,
    target_pane = pane_id,
  }
  vim.b.slime_config = vim.g.slime_default_config

  return session
end

local function encode_status_component(value)
  return (tostring(value or ""):gsub("([^%w%._%-])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function status_root(config)
  local root = config.startup_status_dir
  if type(root) ~= "string" or root == "" then
    root = vim.env.RSCOPE_STATUS_DIR
  end
  if type(root) ~= "string" or root == "" then
    root = (vim.fn.stdpath("state") or "/tmp") .. "/rscope-status"
  end
  return vim.fs.normalize(root)
end

local function status_file_path(session, config)
  if type(session) ~= "table" then
    return nil
  end
  if type(session.tmux_socket) ~= "string" or session.tmux_socket == "" then
    return nil
  end
  if type(session.tmux_session) ~= "string" or session.tmux_session == "" then
    return nil
  end
  if type(session.tmux_pane) ~= "string" or session.tmux_pane == "" then
    return nil
  end

  local filename = table.concat({
    encode_status_component(session.tmux_socket),
    encode_status_component(session.tmux_session),
    encode_status_component(session.tmux_pane),
  }, "__") .. ".json"

  return vim.fs.normalize(status_root(config) .. "/" .. filename)
end

local function mode_has(mode, mask)
  if type(mode) ~= "number" or not bitops or type(bitops.band) ~= "function" then
    return false
  end

  return bitops.band(mode, mask) ~= 0
end

local function status_file_trusted(path)
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

local function read_startup_status(session, config)
  local path = status_file_path(session, config)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  if not status_file_trusted(path) then
    return nil
  end

  local lines = vim.fn.readfile(path)
  if type(lines) ~= "table" or #lines == 0 then
    return nil
  end

  local ok, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(payload) ~= "table" then
    return nil
  end

  payload.port = tonumber(payload.port)
  payload.pid = tonumber(payload.pid)
  payload.ts = tonumber(payload.ts)
  payload.auth_token = type(payload.auth_token) == "string" and payload.auth_token or ""
  payload.log_path = type(payload.log_path) == "string" and payload.log_path or nil
  payload._status_path = path
  return payload
end

local function same_session(lhs, rhs)
  if type(lhs) ~= "table" or type(rhs) ~= "table" then
    return false
  end

  return lhs.tmux_socket == rhs.tmux_socket
    and lhs.tmux_session == rhs.tmux_session
    and lhs.tmux_pane == rhs.tmux_pane
end

local function ping_bridge(session, status, timeout_ms)
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
      tmux_socket = session.tmux_socket,
      tmux_session = session.tmux_session,
      tmux_pane = session.tmux_pane,
    },
  })

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
    return false
  end

  local decoded_ok, payload = pcall(vim.json.decode, table.concat(chunks, ""))
  if not decoded_ok or type(payload) ~= "table" then
    return false
  end
  if payload.status ~= "ok" then
    return false
  end
  if payload.session and not same_session(session, payload.session) then
    return false
  end

  return true
end

local function wait_for_ready_status(session, config)
  local wait_ms = tonumber(config.bridge_wait_ms) or 0
  if wait_ms <= 0 then
    local status = read_startup_status(session, config)
    if status and status.status == "ready" and status.port and ping_bridge(session, status, 250) then
      return status
    end
    return nil
  end

  local ready = nil
  vim.wait(wait_ms, function()
    local status = read_startup_status(session, config)
    if status and status.status == "ready" and status.port and ping_bridge(session, status, 250) then
      ready = status
      return true
    end
    return false
  end, 40, false)

  return ready
end

local function update_state_session(session)
  state.session = session
  sync_compat_state()
end

function M.pane_command(config)
  return "clear && " .. shellescape(config.launcher)
end

function M.session()
  if not pane_exists(state.pane_id) then
    return nil
  end

  local session, err = current_session(state.pane_id)
  if not session then
    vim.schedule(function()
      vim.notify(err, vim.log.levels.WARN, { title = "ark.nvim" })
    end)
    return state.session
  end

  update_state_session(session)
  return vim.deepcopy(state.session)
end

function M.startup_status(config)
  local session = M.session()
  if not session then
    return nil
  end

  return read_startup_status(session, config)
end

function M.bridge_env(config)
  if type(config.session_kind) ~= "string" or config.session_kind == "" then
    return nil
  end

  local session = M.session()
  if not session then
    return nil
  end

  local status = read_startup_status(session, config)
  if not (status and status.status == "ready" and status.port) then
    status = wait_for_ready_status(session, config)
  end
  if not (status and status.status == "ready" and status.port) then
    return nil
  end

  return {
    ARK_SESSION_KIND = config.session_kind,
    ARK_SESSION_HOST = "127.0.0.1",
    ARK_SESSION_PORT = tostring(status.port),
    ARK_SESSION_AUTH_TOKEN = status.auth_token or "",
    ARK_SESSION_TMUX_SOCKET = session.tmux_socket,
    ARK_SESSION_TMUX_SESSION = session.tmux_session,
    ARK_SESSION_TMUX_PANE = session.tmux_pane,
    ARK_SESSION_TIMEOUT_MS = tostring(config.session_timeout_ms or 1000),
  }
end

function M.status(config)
  local session = M.session()
  local startup_status = session and read_startup_status(session, config or {}) or nil
  local bridge_ready = session and startup_status and startup_status.status == "ready"
    and startup_status.port ~= nil and ping_bridge(session, startup_status, 150)
    or false

  return {
    inside_tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= "",
    pane_id = state.pane_id,
    managed = state.managed,
    pane_exists = pane_exists(state.pane_id),
    session = session,
    startup_status = startup_status,
    startup_status_path = session and status_file_path(session, config or {}) or nil,
    bridge_ready = bridge_ready,
  }
end

function M.ensure(config)
  if not vim.env.TMUX or vim.env.TMUX == "" then
    return nil, "ark.nvim requires Neovim to run inside tmux"
  end

  if pane_exists(state.pane_id) then
    local session = M.session()
    if session then
      update_state_session(session)
    end
    return state.pane_id, nil
  end

  local pane_id, split_err = run_tmux({
    "split-window",
    "-h",
    "-p",
    resolve_pane_percent(config),
    "-d",
    "-P",
    "-F",
    "#{pane_id}",
    M.pane_command(config),
  })

  if not pane_id then
    return nil, "failed to create pane: " .. tostring(split_err or "unknown")
  end

  state.pane_id = pane_id
  state.managed = true

  local session = M.session()
  if session then
    update_state_session(session)
  end

  sync_compat_state()
  return pane_id, nil
end

function M.start(opts)
  local pane_id, err = M.ensure(opts.tmux)
  if not pane_id then
    return nil, err
  end

  if opts.configure_slime then
    local session, slime_err = configure_slime_target(pane_id)
    if not session then
      return nil, slime_err
    end
    update_state_session(session)
  end

  return pane_id, nil
end

function M.stop()
  if state.managed and pane_exists(state.pane_id) then
    run_tmux({ "kill-pane", "-t", state.pane_id })
  end

  state.pane_id = nil
  state.managed = false
  state.session = nil
  sync_compat_state()
end

function M.restart(opts)
  M.stop()
  return M.start(opts)
end

return M
