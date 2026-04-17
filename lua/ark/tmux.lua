local uv = vim.uv or vim.loop
local bitops = bit or bit32

local M = {}
local startup_status_cache = {}
local bridge_ping_cache = {}
local prompt_ready_cache = {}
local BRIDGE_PING_CACHE_TTL_MS = 100
local PROMPT_READY_CACHE_TTL_MS = 100

local state = _G.__ark_nvim_state
if type(state) ~= "table" then
  state = {}
end

local function normalize_state(raw)
  raw = raw or {}
  raw.tabs = type(raw.tabs) == "table" and raw.tabs or {}
  raw.active_index = type(raw.active_index) == "number" and raw.active_index or nil
  raw.anchor_pane_id = type(raw.anchor_pane_id) == "string" and raw.anchor_pane_id or nil
  raw.parking_session_name = nil
  raw.slot_width_cells = tonumber(raw.slot_width_cells) or nil
  raw.slot_height_cells = tonumber(raw.slot_height_cells) or nil
  raw.next_tab_id = type(raw.next_tab_id) == "number" and raw.next_tab_id or 1
  raw.managed = raw.managed == true
  raw.pane_id = type(raw.pane_id) == "string" and raw.pane_id or nil
  raw.session = type(raw.session) == "table" and raw.session or nil

  if #raw.tabs == 0 and raw.pane_id then
    raw.tabs[1] = {
      id = raw.next_tab_id,
      pane_id = raw.pane_id,
      session = raw.session,
      visible = true,
      managed = raw.managed ~= false,
      label = "R " .. tostring(raw.next_tab_id),
      parking_window_id = nil,
    }
    raw.active_index = 1
    raw.next_tab_id = raw.next_tab_id + 1
  end

  for _, tab in ipairs(raw.tabs) do
    if type(tab) == "table" then
      tab.id = type(tab.id) == "number" and tab.id or raw.next_tab_id
      if tab.id >= raw.next_tab_id then
        raw.next_tab_id = tab.id + 1
      end
      tab.pane_id = type(tab.pane_id) == "string" and tab.pane_id or nil
      tab.session = type(tab.session) == "table" and tab.session or nil
      tab.visible = tab.visible == true
      tab.managed = tab.managed ~= false
      tab.label = type(tab.label) == "string" and tab.label or ("R " .. tostring(tab.id))
      tab.parking_window_id = type(tab.parking_window_id) == "string" and tab.parking_window_id or nil
    end
  end

  if raw.active_index and not raw.tabs[raw.active_index] then
    raw.active_index = nil
  end

  return raw
end

state = normalize_state(state)
_G.__ark_nvim_state = state

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function run_tmux(args)
  local command = { "tmux" }
  local explicit_socket = vim.env.ARK_TMUX_SOCKET
  if type(explicit_socket) == "string" and explicit_socket ~= "" then
    command[#command + 1] = "-S"
    command[#command + 1] = explicit_socket
  else
    local tmux_env = vim.env.TMUX
    if type(tmux_env) == "string" and tmux_env ~= "" then
      local socket = vim.split(tmux_env, ",", { plain = true })[1]
      if type(socket) == "string" and socket ~= "" then
        command[#command + 1] = "-S"
        command[#command + 1] = socket
      end
    end
  end
  vim.list_extend(command, args)

  local output = vim.fn.system(command)
  if vim.v.shell_error ~= 0 then
    return nil, trim(output)
  end

  return trim(output), nil
end

local function strip_ansi(text)
  return (text or ""):gsub("\27%[[0-9;]*[%a]", "")
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

  local out = run_tmux({ "display-message", "-p", "-t", pane_id, "#{pane_id}" })
  return out == pane_id
end

local function session_exists(session_name)
  if not session_name or session_name == "" then
    return false
  end

  local out = run_tmux({ "display-message", "-p", "-t", session_name, "#{session_name}" })
  return out == session_name
end

local function active_tab()
  return state.active_index and state.tabs[state.active_index] or nil
end

local function sync_compat_state()
  local current = active_tab()
  local pane_id = current and current.pane_id or nil
  local managed = #state.tabs > 0

  state.pane_id = pane_id
  state.managed = managed
  state.session = current and current.session or nil

  _G.__r_repl_state = {
    pane_id = pane_id,
    managed = managed,
  }
end

local function update_active_index(index)
  state.active_index = index
  sync_compat_state()
end

sync_compat_state()

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

  return nil
end

local function pane_percent_for_layout(config, layout_name)
  if layout_name == "stacked" then
    local stacked = parse_percent(tostring(config.stacked_pane_percent or ""))
    if stacked then
      return stacked
    end
  else
    local from_env = resolve_pane_percent(config)
    if from_env then
      return from_env
    end
  end

  local pct = parse_percent(tostring(config.pane_percent or ""))
  if pct then
    return pct
  end

  if layout_name == "stacked" then
    return "50"
  end

  return "33"
end

local function current_tmux_pane()
  local explicit_anchor = vim.env.ARK_TMUX_ANCHOR_PANE
  if type(explicit_anchor) == "string" and explicit_anchor ~= "" and pane_exists(explicit_anchor) then
    return explicit_anchor, nil
  end

  local tmux_pane = vim.env.TMUX_PANE
  if type(tmux_pane) == "string" and tmux_pane ~= "" and pane_exists(tmux_pane) then
    return tmux_pane, nil
  end

  local pane_id, err = run_tmux({ "display-message", "-p", "#{pane_id}" })
  if not pane_id then
    return nil, "failed to determine current tmux pane: " .. tostring(err or "unknown")
  end

  return pane_id, nil
end

local function current_session(pane_id)
  local target = pane_id or state.pane_id or vim.env.ARK_TMUX_ANCHOR_PANE or vim.env.TMUX_PANE
  if type(target) ~= "string" or target == "" then
    local explicit_session = vim.env.ARK_TMUX_SESSION
    local explicit_socket = vim.env.ARK_TMUX_SOCKET
    local explicit_pane = vim.env.ARK_TMUX_ANCHOR_PANE
    if type(explicit_socket) == "string"
      and explicit_socket ~= ""
      and type(explicit_session) == "string"
      and explicit_session ~= ""
      and type(explicit_pane) == "string"
      and explicit_pane ~= ""
    then
      return {
        tmux_socket = explicit_socket,
        tmux_session = explicit_session,
        tmux_pane = explicit_pane,
      }, nil
    end

    return nil, "managed tmux pane is missing"
  end

  local session_info, session_err = run_tmux({
    "display-message",
    "-p",
    "-t",
    target,
    "#{socket_path}\n#{session_name}",
  })
  if not session_info then
    return nil, "failed to get tmux session info: " .. tostring(session_err or "unknown")
  end

  local socket_path, session_name = session_info:match("^([^\n]+)\n([^\n]+)$")
  if not socket_path or not session_name then
    return nil, "failed to parse tmux session info: " .. tostring(session_info)
  end

  return {
    tmux_socket = socket_path,
    tmux_session = session_name,
    tmux_pane = target,
  }, nil
end

local function tmux_context_available()
  return (type(vim.env.ARK_TMUX_SOCKET) == "string" and vim.env.ARK_TMUX_SOCKET ~= "")
    or (type(vim.env.TMUX) == "string" and vim.env.TMUX ~= "")
end

local function session_from_parts(pane_id, socket_path, session_name)
  if type(pane_id) ~= "string" or pane_id == "" then
    return nil
  end
  if type(socket_path) ~= "string" or socket_path == "" then
    return nil
  end
  if type(session_name) ~= "string" or session_name == "" then
    return nil
  end

  return {
    tmux_socket = socket_path,
    tmux_session = session_name,
    tmux_pane = pane_id,
  }
end

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function configure_slime_target(pane_id, filetypes, known_session)
  local session = known_session
  local err = nil
  if type(session) ~= "table" or session.tmux_pane ~= pane_id then
    session, err = current_session(pane_id)
  end
  if not session then
    return nil, err
  end

  vim.g.slime_target = "tmux"
  vim.g.slime_default_config = {
    socket_name = session.tmux_socket,
    target_pane = pane_id,
  }

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and filetype_enabled(filetypes, vim.bo[bufnr].filetype) then
      vim.b[bufnr].slime_config = vim.deepcopy(vim.g.slime_default_config)
    end
  end

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
    root = vim.env.ARK_STATUS_DIR
  end
  if type(root) ~= "string" or root == "" then
    root = (vim.fn.stdpath("state") or "/tmp") .. "/ark-status"
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
    startup_status_cache[path or ""] = nil
    return nil
  end
  if not status_file_trusted(path) then
    startup_status_cache[path] = nil
    return nil
  end

  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  local cached = startup_status_cache[path]
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
    startup_status_cache[path] = nil
    return nil
  end

  local ok, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(payload) ~= "table" then
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

  local cache_key = table.concat({
    session.tmux_socket or "",
    session.tmux_session or "",
    session.tmux_pane or "",
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

local function prompt_ready(session)
  if type(session) ~= "table" or type(session.tmux_pane) ~= "string" or session.tmux_pane == "" then
    return false
  end

  local cached = prompt_ready_cache[session.tmux_pane]
  if type(cached) == "table" and monotonic_ms() - (tonumber(cached.checked_ms) or 0) < PROMPT_READY_CACHE_TTL_MS then
    return cached.result == true
  end

  local capture = run_tmux({ "capture-pane", "-p", "-t", session.tmux_pane })
  if type(capture) ~= "string" or capture == "" then
    prompt_ready_cache[session.tmux_pane] = {
      checked_ms = monotonic_ms(),
      result = false,
    }
    return false
  end

  local last_line = ""
  for line in (strip_ansi(capture) .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      last_line = line
    end
  end

  last_line = trim((last_line or ""):gsub("\r", ""))
  local ready = last_line:sub(-1) == ">"
  prompt_ready_cache[session.tmux_pane] = {
    checked_ms = monotonic_ms(),
    result = ready,
  }
  return ready
end

local function bridge_env_payload(config, session, status_path)
  if type(config.session_kind) ~= "string" or config.session_kind == "" then
    return nil
  end
  if type(session) ~= "table" then
    return nil
  end
  if type(status_path) ~= "string" or status_path == "" then
    return nil
  end

  return {
    ARK_SESSION_KIND = config.session_kind,
    ARK_SESSION_STATUS_FILE = status_path,
    ARK_SESSION_TMUX_SOCKET = session.tmux_socket,
    ARK_SESSION_TMUX_SESSION = session.tmux_session,
    ARK_SESSION_TMUX_PANE = session.tmux_pane,
    ARK_SESSION_TIMEOUT_MS = tostring(config.session_timeout_ms or 1000),
  }
end

local function refresh_visible_tab_session(index)
  local tab = state.tabs[index]
  if type(tab) ~= "table" or tab.visible ~= true or not tab.pane_id or not pane_exists(tab.pane_id) then
    return tab and tab.session or nil
  end

  local session, err = current_session(tab.pane_id)
  if not session then
    vim.schedule(function()
      vim.notify(err, vim.log.levels.WARN, { title = "ark.nvim" })
    end)
    return tab.session
  end

  tab.session = session
  return session
end

local function cleanup_parking_session()
  state.parking_session_name = nil
end

local function tab_badge_text(index, count)
  if not index or not state.tabs[index] then
    return nil
  end

  if (count or #state.tabs) <= 1 then
    return string.format("[%d]", index)
  end

  return string.format("[%d/%d]", index, count or #state.tabs)
end

local function prune_dead_tabs()
  local removed_active = false
  for index = #state.tabs, 1, -1 do
    local tab = state.tabs[index]
    if not pane_exists(tab.pane_id) then
      table.remove(state.tabs, index)
      if state.active_index == index then
        removed_active = true
      elseif state.active_index and state.active_index > index then
        state.active_index = state.active_index - 1
      end
    end
  end

  if #state.tabs == 0 then
    state.active_index = nil
    state.anchor_pane_id = nil
    cleanup_parking_session()
  elseif removed_active and not state.tabs[state.active_index or 0] then
    state.active_index = nil
  end

  sync_compat_state()
end

local function set_active_tab(index)
  if not index then
    update_active_index(nil)
    return
  end

  refresh_visible_tab_session(index)
  update_active_index(index)
end

local function ensure_anchor_pane()
  if state.anchor_pane_id and pane_exists(state.anchor_pane_id) then
    return state.anchor_pane_id, nil
  end

  if state.anchor_pane_id and #state.tabs > 0 then
    return nil, "ark.nvim anchor pane disappeared; run :ArkPaneStart from the pane that should host Ark"
  end

  local pane_id, err = current_tmux_pane()
  if not pane_id then
    return nil, err
  end

  state.anchor_pane_id = pane_id
  return pane_id, nil
end

local function window_width(target)
  local width, err = run_tmux({ "display-message", "-p", "-t", target, "#{window_width}" })
  if not width then
    return nil, "failed to resolve tmux window width: " .. tostring(err or "unknown")
  end

  width = tonumber(width)
  if not width or width <= 0 then
    return nil, "failed to parse tmux window width: " .. tostring(width)
  end

  return width, nil
end

local function window_height(target)
  local height, err = run_tmux({ "display-message", "-p", "-t", target, "#{window_height}" })
  if not height then
    return nil, "failed to resolve tmux window height: " .. tostring(err or "unknown")
  end

  height = tonumber(height)
  if not height or height <= 0 then
    return nil, "failed to parse tmux window height: " .. tostring(height)
  end

  return height, nil
end

local function current_pane_width(pane_id)
  local width, err = run_tmux({ "display-message", "-p", "-t", pane_id, "#{pane_width}" })
  if not width then
    return nil, "failed to resolve tmux pane width: " .. tostring(err or "unknown")
  end

  width = tonumber(width)
  if not width or width <= 0 then
    return nil, "failed to parse tmux pane width: " .. tostring(width)
  end

  return width, nil
end

local function current_pane_height(pane_id)
  local height, err = run_tmux({ "display-message", "-p", "-t", pane_id, "#{pane_height}" })
  if not height then
    return nil, "failed to resolve tmux pane height: " .. tostring(err or "unknown")
  end

  height = tonumber(height)
  if not height or height <= 0 then
    return nil, "failed to parse tmux pane height: " .. tostring(height)
  end

  return height, nil
end

local function normalize_pane_layout(value)
  if value == nil then
    return "auto"
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end

  value = value:lower()
  if value == "auto" then
    return value
  end
  if value == "side_by_side" or value == "horizontal" or value == "landscape" then
    return "side_by_side"
  end
  if value == "stacked" or value == "vertical" or value == "portrait" then
    return "stacked"
  end

  return nil
end

local function pane_layout(name)
  if name == "stacked" then
    return {
      name = "stacked",
      split_flag = "-v",
    }
  end

  return {
    name = "side_by_side",
    split_flag = "-h",
  }
end

local function resolve_pane_layout(target, config)
  local layout_name = normalize_pane_layout(config.pane_layout)
  if not layout_name then
    return nil, "invalid ark.nvim tmux.pane_layout: " .. tostring(config.pane_layout)
  end

  if layout_name ~= "auto" then
    return pane_layout(layout_name), nil
  end

  local width, width_err = window_width(target)
  if not width then
    return nil, width_err
  end

  local stacked_max_width = tonumber(config.stacked_max_width)
  if stacked_max_width and stacked_max_width > 0 and width <= stacked_max_width then
    return pane_layout("stacked"), nil
  end

  local height, height_err = window_height(target)
  if not height then
    return nil, height_err
  end

  if height > width then
    return pane_layout("stacked"), nil
  end

  return pane_layout("side_by_side"), nil
end

local function active_pane_layout(pane_id, config)
  local pane_width, pane_width_err = current_pane_width(pane_id)
  if not pane_width then
    return nil, pane_width_err
  end

  local total_width, total_width_err = window_width(pane_id)
  if not total_width then
    return nil, total_width_err
  end

  if pane_width < total_width then
    return pane_layout("side_by_side"), nil
  end

  local pane_height, pane_height_err = current_pane_height(pane_id)
  if not pane_height then
    return nil, pane_height_err
  end

  local total_height, total_height_err = window_height(pane_id)
  if not total_height then
    return nil, total_height_err
  end

  if pane_height < total_height then
    return pane_layout("stacked"), nil
  end

  return resolve_pane_layout(pane_id, config)
end

local function slot_size_cells(layout)
  if layout.name == "stacked" then
    return state.slot_height_cells
  end

  return state.slot_width_cells
end

local function set_slot_size_cells(layout, cells)
  if layout.name == "stacked" then
    state.slot_height_cells = cells
    return
  end

  state.slot_width_cells = cells
end

local function desired_slot_size(anchor_pane_id, config, layout)
  local stored = slot_size_cells(layout)
  if stored and stored > 0 then
    return tostring(stored), nil
  end

  local total, err
  if layout.name == "stacked" then
    total, err = window_height(anchor_pane_id)
  else
    total, err = window_width(anchor_pane_id)
  end
  if not total then
    return nil, err
  end

  local pct = tonumber(pane_percent_for_layout(config, layout.name)) or tonumber(config.pane_percent) or 33
  local cells = math.floor((total * pct) / 100)
  if cells < 10 then
    cells = 10
  elseif cells >= total then
    cells = math.max(10, total - 1)
  end

  return tostring(cells), nil
end

local function insert_tab(tab, index)
  if index and index >= 1 and index <= (#state.tabs + 1) then
    table.insert(state.tabs, index, tab)
    return index
  end

  table.insert(state.tabs, tab)
  return #state.tabs
end

local function next_tab_record(pane_id, visible)
  local id = state.next_tab_id
  state.next_tab_id = id + 1
  return {
    id = id,
    pane_id = pane_id,
    session = nil,
    visible = visible == true,
    managed = true,
    label = "R " .. tostring(id),
    parking_window_id = nil,
  }
end

local function parking_window_name(tab)
  return "__ark_tab_" .. tostring(tab.id) .. "__"
end

local function main_session_name()
  local anchor_pane_id, anchor_err = ensure_anchor_pane()
  if not anchor_pane_id then
    return nil, anchor_err
  end

  local session, session_err = current_session(anchor_pane_id)
  if not session then
    return nil, session_err
  end

  return session.tmux_session, nil
end

local function create_visible_tab(opts, insert_index)
  local anchor_pane_id, anchor_err = ensure_anchor_pane()
  if not anchor_pane_id then
    return nil, nil, anchor_err
  end

  local layout, layout_err = resolve_pane_layout(anchor_pane_id, opts.tmux)
  if not layout then
    return nil, nil, layout_err
  end

  local output, split_err = run_tmux({
    "split-window",
    layout.split_flag,
    "-p",
    pane_percent_for_layout(opts.tmux, layout.name),
    "-d",
    "-P",
    "-F",
    "#{pane_id}\n#{socket_path}\n#{session_name}",
    "-t",
    anchor_pane_id,
    M.pane_command(opts.tmux),
  })
  if not output then
    return nil, nil, "failed to create pane: " .. tostring(split_err or "unknown")
  end

  local pane_id, socket_path, session_name = output:match("^([^\n]+)\n([^\n]+)\n([^\n]+)$")
  if not pane_id or not socket_path or not session_name then
    return nil, nil, "failed to parse pane session info: " .. tostring(output)
  end

  local session = session_from_parts(pane_id, socket_path, session_name)
  local tab = next_tab_record(pane_id, true)
  tab.session = session
  local index = insert_tab(tab, insert_index)
  set_active_tab(index)
  return pane_id, session, nil
end

local function create_hidden_tab(opts, insert_index)
  local session_name, session_err = main_session_name()
  if not session_name then
    return nil, nil, session_err
  end

  local tab = next_tab_record(nil, false)
  local output, err = run_tmux({
    "new-window",
    "-d",
    "-P",
    "-F",
    "#{pane_id}\n#{window_id}\n#{socket_path}\n#{session_name}",
    "-t",
    session_name .. ":",
    "-n",
    parking_window_name(tab),
    M.pane_command(opts.tmux),
  })
  if not output then
    return nil, nil, "failed to create hidden ark.nvim tab: " .. tostring(err or "unknown")
  end

  local pane_id, window_id, socket_path, new_session_name = output:match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]+)$")
  if not pane_id or not window_id or not socket_path or not new_session_name then
    return nil, nil, "failed to parse hidden ark.nvim tab identifiers: " .. tostring(output)
  end

  tab.pane_id = pane_id
  tab.parking_window_id = window_id
  tab.session = session_from_parts(pane_id, socket_path, new_session_name)

  local index = insert_tab(tab, insert_index)
  return pane_id, index, nil
end

local function park_tab(index, config)
  local tab = state.tabs[index]
  if not tab or tab.visible ~= true or not tab.pane_id or not pane_exists(tab.pane_id) then
    return true, nil
  end

  local session = refresh_visible_tab_session(index)
  if session then
    tab.session = session
  end

  local layout, layout_err = active_pane_layout(tab.pane_id, config or {})
  if not layout then
    return nil, layout_err
  end

  local size = nil
  if layout.name == "stacked" then
    size = current_pane_height(tab.pane_id)
  else
    size = current_pane_width(tab.pane_id)
  end
  if size then
    set_slot_size_cells(layout, size)
  end

  local session_name, session_err = main_session_name()
  if not session_name then
    return nil, session_err
  end

  local window_id, err = run_tmux({
    "break-pane",
    "-d",
    "-P",
    "-F",
    "#{window_id}",
    "-s",
    tab.pane_id,
    "-t",
    session_name .. ":",
    "-n",
    parking_window_name(tab),
  })
  if not window_id then
    return nil, "failed to park pane: " .. tostring(err or "unknown")
  end

  tab.visible = false
  tab.parking_window_id = window_id
  if state.active_index == index then
    update_active_index(nil)
  end

  return true, nil
end

local function restore_tab(index, config)
  local tab = state.tabs[index]
  if not tab then
    return nil, "ark.nvim tab does not exist"
  end
  if tab.visible == true and pane_exists(tab.pane_id) then
    set_active_tab(index)
    return tab.pane_id, nil
  end

  local anchor_pane_id, anchor_err = ensure_anchor_pane()
  if not anchor_pane_id then
    return nil, anchor_err
  end

  local layout, layout_err = resolve_pane_layout(anchor_pane_id, config)
  if not layout then
    return nil, layout_err
  end

  local size, size_err = desired_slot_size(anchor_pane_id, config, layout)
  if not size then
    return nil, size_err
  end

  local _, join_err = run_tmux({
    "join-pane",
    "-d",
    layout.split_flag,
    "-l",
    size,
    "-s",
    tab.pane_id,
    "-t",
    anchor_pane_id,
  })
  if join_err then
    return nil, "failed to restore pane: " .. tostring(join_err or "unknown")
  end

  tab.visible = true
  tab.parking_window_id = nil
  refresh_visible_tab_session(index)
  set_active_tab(index)
  return tab.pane_id, nil
end

local function swap_active_tab(index, config)
  local current_index = state.active_index
  local current = current_index and state.tabs[current_index] or nil
  local target = state.tabs[index]
  if not current or not target then
    return nil, "ark.nvim tab does not exist"
  end
  if current.visible ~= true or target.visible == true then
    return nil, "ark.nvim tab swap requires one visible and one parked tab"
  end
  if not pane_exists(current.pane_id) or not pane_exists(target.pane_id) then
    return nil, "ark.nvim tab swap requires live panes"
  end

  local current_session = refresh_visible_tab_session(current_index)
  if current_session then
    current.session = current_session
  end

  local layout, layout_err = active_pane_layout(current.pane_id, config or {})
  if not layout then
    return nil, layout_err
  end

  local size = nil
  if layout.name == "stacked" then
    size = current_pane_height(current.pane_id)
  else
    size = current_pane_width(current.pane_id)
  end
  if size then
    set_slot_size_cells(layout, size)
  end

  local _, swap_err = run_tmux({
    "swap-pane",
    "-d",
    "-s",
    target.pane_id,
    "-t",
    current.pane_id,
  })
  if swap_err then
    return nil, "failed to swap pane: " .. tostring(swap_err or "unknown")
  end

  current.visible = false
  current.parking_window_id = target.parking_window_id
  target.visible = true
  target.parking_window_id = nil

  refresh_visible_tab_session(index)
  set_active_tab(index)
  return target.pane_id, nil
end

local function active_startup_session()
  prune_dead_tabs()
  local current = active_tab()
  if not current or current.visible ~= true or not current.pane_id or not pane_exists(current.pane_id) then
    return nil
  end

  return M.session()
end

function M.pane_command(config)
  local exports = {
    "ARK_STATUS_DIR=" .. vim.fn.shellescape(config.startup_status_dir),
    "ARK_NVIM_SESSION_PKG_PATH=" .. vim.fn.shellescape(config.session_pkg_path),
  }

  if type(config.session_lib_path) == "string" and config.session_lib_path ~= "" then
    table.insert(exports, "ARK_NVIM_SESSION_LIB=" .. vim.fn.shellescape(config.session_lib_path))
  end

  return "export " .. table.concat(exports, " ")
    .. "; clear && exec "
    .. vim.fn.shellescape(config.launcher)
end

function M.session()
  prune_dead_tabs()
  local current = active_tab()
  if not current or current.visible ~= true or not pane_exists(current.pane_id) then
    return nil
  end

  local session = refresh_visible_tab_session(state.active_index)
  if session then
    update_active_index(state.active_index)
  end
  return session and vim.deepcopy(session) or nil
end

function M.startup_snapshot(config, snapshot_opts)
  config = config or {}
  snapshot_opts = snapshot_opts or {}

  local session = active_startup_session()
  if not session then
    return nil
  end

  local status_path = status_file_path(session, config)
  local authoritative_status = read_startup_status(session, config)
  local startup_status = authoritative_status and vim.deepcopy(authoritative_status) or nil
  if startup_status and startup_status.repl_ready ~= true and snapshot_opts.include_prompt_ready == true then
    if prompt_ready(session) then
      startup_status.repl_ready = true
    end
  end

  local bridge_ready = false
  if type(authoritative_status) == "table"
    and authoritative_status.status == "ready"
    and authoritative_status.port ~= nil
    and type(authoritative_status.auth_token) == "string"
    and authoritative_status.auth_token ~= ""
  then
    if snapshot_opts.validate_bridge == false then
      bridge_ready = true
    else
      local timeout_ms = tonumber(snapshot_opts.bridge_timeout_ms or snapshot_opts.timeout_ms or 150) or 150
      bridge_ready = ping_bridge(session, authoritative_status, timeout_ms)
    end
  end

  return {
    session = vim.deepcopy(session),
    status_path = status_path,
    startup_status_path = status_path,
    startup_status = startup_status,
    authoritative_status = authoritative_status and vim.deepcopy(authoritative_status) or nil,
    bridge_ready = bridge_ready,
    cmd_env = bridge_ready and bridge_env_payload(config, session, status_path) or nil,
  }
end

function M.startup_status(config)
  local snapshot = M.startup_snapshot(config, {
    include_prompt_ready = true,
    validate_bridge = false,
  })
  return snapshot and snapshot.startup_status or nil
end

function M.startup_status_authoritative(config)
  local snapshot = M.startup_snapshot(config, {
    validate_bridge = false,
  })
  return snapshot and snapshot.authoritative_status or nil
end

function M.startup_status_path(config)
  local snapshot = M.startup_snapshot(config, {
    validate_bridge = false,
  })
  return snapshot and snapshot.startup_status_path or nil
end

function M.bridge_env(config, snapshot)
  local current = type(snapshot) == "table" and snapshot or M.startup_snapshot(config, {
    validate_bridge = false,
  })
  return current and current.cmd_env or nil
end

function M.send_text(text)
  local session = active_startup_session()
  if not session or type(session.tmux_pane) ~= "string" or session.tmux_pane == "" then
    return nil, "ark.nvim has no active managed pane"
  end

  if type(text) ~= "string" or text == "" then
    return nil, "ark.nvim send_text() requires non-empty text"
  end

  local _, err = run_tmux({ "send-keys", "-t", session.tmux_pane, text, "Enter" })
  if err then
    return nil, err
  end

  return true, nil
end

local function tab_summaries(config)
  local tabs = {}
  for index, tab in ipairs(state.tabs) do
    local alive = pane_exists(tab.pane_id)
    local session = tab.session
    if tab.visible == true and alive then
      session = refresh_visible_tab_session(index)
    end
    tabs[#tabs + 1] = {
      id = tab.id,
      index = index,
      label = tab.label,
      pane_id = tab.pane_id,
      visible = tab.visible == true,
      active = state.active_index == index,
      alive = alive,
      managed = tab.managed ~= false,
      session = session,
      startup_status_path = session and status_file_path(session, config or {}) or nil,
      parking_window_id = tab.parking_window_id,
    }
  end
  return tabs
end

function M.tab_state()
  local index = state.active_index
  local current = index and state.tabs[index] or nil
  return {
    active_index = current and index or nil,
    active_id = current and current.id or nil,
    tab_count = #state.tabs,
    text = current and tab_badge_text(index, #state.tabs) or nil,
  }
end

function M.tab_badge()
  return M.tab_state().text
end

function M.status(config)
  prune_dead_tabs()
  local session = M.session()
  local snapshot = session and M.startup_snapshot(config or {}, {
    include_prompt_ready = true,
    validate_bridge = true,
  }) or nil
  local startup_status = snapshot and snapshot.startup_status or nil
  local bridge_ready = snapshot and snapshot.bridge_ready == true or false

  return {
    inside_tmux = tmux_context_available(),
    pane_id = state.pane_id,
    managed = state.managed,
    pane_exists = pane_exists(state.pane_id),
    session = session,
    startup_status = startup_status,
    startup_status_path = snapshot and snapshot.startup_status_path or nil,
    bridge_ready = bridge_ready,
    repl_ready = bridge_ready and startup_status and startup_status.repl_ready == true or false,
    anchor_pane_id = state.anchor_pane_id,
    parking_session_name = state.parking_session_name,
    slot_width_cells = state.slot_width_cells,
    slot_height_cells = state.slot_height_cells,
    active_index = state.active_index,
    tab_count = #state.tabs,
    tabs = tab_summaries(config),
  }
end

function M.tab_new(opts)
  if not tmux_context_available() then
    return nil, "ark.nvim requires Neovim to run inside tmux"
  end

  prune_dead_tabs()
  local pane_id
  if state.active_index and active_tab() and active_tab().visible == true then
    local _, index, create_err = create_hidden_tab(opts)
    if not index then
      return nil, create_err
    end

    local swapped_pane_id, swap_err = swap_active_tab(index, opts.tmux)
    if not swapped_pane_id then
      return nil, swap_err
    end
    pane_id = swapped_pane_id
  elseif #state.tabs == 0 then
    local created_pane_id, created_session, create_err = create_visible_tab(opts)
    if not created_pane_id then
      return nil, create_err
    end
    pane_id = created_pane_id
    state.session = created_session
  else
    local _, index, create_err = create_hidden_tab(opts)
    if not index then
      return nil, create_err
    end

    local restored_pane_id, restore_err = restore_tab(index, opts.tmux)
    if not restored_pane_id then
      return nil, restore_err
    end
    pane_id = restored_pane_id
  end

  if opts.configure_slime then
    local known_session = state.session
    local session, slime_err = configure_slime_target(pane_id, opts.filetypes, known_session)
    if not session then
      return nil, slime_err
    end
    state.session = session
  end

  return pane_id, nil
end

function M.tab_select(index, opts)
  prune_dead_tabs()
  if #state.tabs == 0 then
    return nil, "ark.nvim has no managed tabs"
  end

  index = tonumber(index)
  if not index or not state.tabs[index] then
    return nil, "ark.nvim tab index is out of range"
  end

  if state.active_index == index and active_tab() and active_tab().visible == true and pane_exists(state.pane_id) then
    if opts.configure_slime then
      local session, slime_err = configure_slime_target(state.pane_id, opts.filetypes, active_tab() and active_tab().session or nil)
      if not session then
        return nil, slime_err
      end
      state.session = session
    end
    return state.pane_id, nil
  end

  if state.active_index and active_tab() and active_tab().visible == true then
    local pane_id, swap_err = swap_active_tab(index, opts.tmux)
    if not pane_id then
      return nil, swap_err
    end

    if opts.configure_slime then
      local session, slime_err = configure_slime_target(pane_id, opts.filetypes, state.tabs[index] and state.tabs[index].session or nil)
      if not session then
        return nil, slime_err
      end
      state.session = session
    end

    return pane_id, nil
  end

  local pane_id, restore_err = restore_tab(index, opts.tmux)
  if not pane_id then
    return nil, restore_err
  end

  if opts.configure_slime then
    local session, slime_err = configure_slime_target(pane_id, opts.filetypes, state.tabs[index] and state.tabs[index].session or nil)
    if not session then
      return nil, slime_err
    end
    state.session = session
  end

  return pane_id, nil
end

function M.tab_go(index, opts)
  return M.tab_select(index, opts)
end

function M.tab_next(opts)
  prune_dead_tabs()
  if #state.tabs == 0 then
    return nil, "ark.nvim has no managed tabs"
  end

  local index = state.active_index or 1
  index = index + 1
  if index > #state.tabs then
    index = 1
  end

  return M.tab_select(index, opts)
end

function M.tab_prev(opts)
  prune_dead_tabs()
  if #state.tabs == 0 then
    return nil, "ark.nvim has no managed tabs"
  end

  local index = state.active_index or 1
  index = index - 1
  if index < 1 then
    index = #state.tabs
  end

  return M.tab_select(index, opts)
end

function M.tab_close(opts)
  prune_dead_tabs()
  local current = active_tab()
  if not current then
    return nil, "ark.nvim has no active tab"
  end

  local closing_index = state.active_index
  if #state.tabs == 1 then
    if pane_exists(current.pane_id) then
      run_tmux({ "kill-pane", "-t", current.pane_id })
    end
    table.remove(state.tabs, closing_index)
    state.active_index = nil
    state.anchor_pane_id = nil
    sync_compat_state()
    return nil, nil
  end

  local next_index = math.min(closing_index, #state.tabs)
  if next_index == closing_index then
    next_index = math.max(1, closing_index - 1)
  end

  local promoted_pane_id = nil
  if next_index ~= closing_index and state.tabs[next_index] and state.tabs[next_index].visible ~= true then
    local swapped_pane_id, swap_err = swap_active_tab(next_index, opts.tmux)
    if not swapped_pane_id then
      return nil, swap_err
    end
    promoted_pane_id = swapped_pane_id

    if pane_exists(current.pane_id) then
      run_tmux({ "kill-pane", "-t", current.pane_id })
    end

    if next_index < closing_index then
      table.remove(state.tabs, closing_index)
      state.active_index = next_index
    else
      table.remove(state.tabs, closing_index)
      state.active_index = next_index - 1
    end
    sync_compat_state()
    if opts.configure_slime then
      local session, slime_err = configure_slime_target(promoted_pane_id, opts.filetypes)
      if not session then
        return nil, slime_err
      end
      state.session = session
    end
    return promoted_pane_id, nil
  end

  if pane_exists(current.pane_id) then
    run_tmux({ "kill-pane", "-t", current.pane_id })
  end
  table.remove(state.tabs, closing_index)
  state.active_index = nil
  sync_compat_state()
  local pane_id, err = M.tab_select(next_index, opts)
  if not pane_id then
    return nil, err
  end
  return pane_id, nil
end

function M.tab_list()
  prune_dead_tabs()
  return vim.deepcopy(tab_summaries({}))
end

function M.start(opts)
  if not tmux_context_available() then
    return nil, "ark.nvim requires Neovim to run inside tmux"
  end

  prune_dead_tabs()

  if state.active_index and active_tab() and active_tab().visible == true and pane_exists(state.pane_id) then
    if opts.configure_slime then
      local session, slime_err = configure_slime_target(state.pane_id, opts.filetypes, active_tab() and active_tab().session or nil)
      if not session then
        return nil, slime_err
      end
      state.session = session
    end
    return state.pane_id, nil
  end

  if #state.tabs > 0 then
    return M.tab_select(state.active_index or 1, opts)
  end

  return M.tab_new(opts)
end

function M.stop_all()
  for _, tab in ipairs(state.tabs) do
    if pane_exists(tab.pane_id) then
      run_tmux({ "kill-pane", "-t", tab.pane_id })
    end
  end

  cleanup_parking_session()

  state.tabs = {}
  state.active_index = nil
  state.anchor_pane_id = nil
  state.parking_session_name = nil
  state.slot_width_cells = nil
  state.slot_height_cells = nil
  state.session = nil
  state.pane_id = nil
  state.managed = false
  sync_compat_state()
end

function M.stop()
  M.stop_all()
end

function M.restart(opts)
  if not tmux_context_available() then
    return nil, "ark.nvim requires Neovim to run inside tmux"
  end

  prune_dead_tabs()
  if not active_tab() then
    return M.start(opts)
  end

  local restart_index = state.active_index
  local current = active_tab()
  local pane_id

  if current and current.visible == true and pane_exists(current.pane_id) then
    local _, replacement_index, create_err = create_hidden_tab(opts, restart_index + 1)
    if not replacement_index then
      return nil, create_err
    end

    local swapped_pane_id, swap_err = swap_active_tab(replacement_index, opts.tmux)
    if not swapped_pane_id then
      return nil, swap_err
    end

    if pane_exists(current.pane_id) then
      run_tmux({ "kill-pane", "-t", current.pane_id })
    end

    table.remove(state.tabs, restart_index)
    state.active_index = replacement_index - 1
    sync_compat_state()
    pane_id = swapped_pane_id
  else
    table.remove(state.tabs, restart_index)
    state.active_index = nil
    sync_compat_state()

    local created_pane_id, created_session, err = create_visible_tab(opts, restart_index)
    if not created_pane_id then
      return nil, err
    end
    pane_id = created_pane_id
    state.session = created_session
  end

  if opts.configure_slime then
    local session, slime_err = configure_slime_target(pane_id, opts.filetypes, state.session)
    if not session then
      return nil, slime_err
    end
    state.session = session
  end

  return pane_id, nil
end

return M
