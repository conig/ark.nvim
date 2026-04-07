local uv = vim.uv or vim.loop
local bitops = bit or bit32

local M = {}

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

local function run_tmux(args)
  local command = { "tmux" }
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

  return tostring(config.pane_percent)
end

local function current_tmux_pane()
  local pane_id, err = run_tmux({ "display-message", "-p", "#{pane_id}" })
  if not pane_id then
    return nil, "failed to determine current tmux pane: " .. tostring(err or "unknown")
  end

  return pane_id, nil
end

local function current_session(pane_id)
  local target = pane_id or state.pane_id
  if type(target) ~= "string" or target == "" then
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
    root = vim.env.RSCOPE_STATUS_DIR
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
  payload.repl_ts = tonumber(payload.repl_ts)
  payload.repl_seq = tonumber(payload.repl_seq)
  payload.auth_token = type(payload.auth_token) == "string" and payload.auth_token or ""
  payload.repl_ready = payload.repl_ready == true or payload.repl_ready == 1
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

local function prompt_ready(session)
  if type(session) ~= "table" or type(session.tmux_pane) ~= "string" or session.tmux_pane == "" then
    return false
  end

  local capture = run_tmux({ "capture-pane", "-p", "-t", session.tmux_pane })
  if type(capture) ~= "string" or capture == "" then
    return false
  end

  local last_line = ""
  for line in (strip_ansi(capture) .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      last_line = line
    end
  end

  last_line = trim((last_line or ""):gsub("\r", ""))
  return last_line:sub(-1) == ">"
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

local function desired_slot_width(anchor_pane_id, config)
  if state.slot_width_cells and state.slot_width_cells > 0 then
    return tostring(state.slot_width_cells), nil
  end

  local width, err = window_width(anchor_pane_id)
  if not width then
    return nil, err
  end

  local pct = tonumber(resolve_pane_percent(config)) or tonumber(config.pane_percent) or 33
  local cells = math.floor((width * pct) / 100)
  if cells < 10 then
    cells = 10
  elseif cells >= width then
    cells = math.max(10, width - 1)
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

  local output, split_err = run_tmux({
    "split-window",
    "-h",
    "-p",
    resolve_pane_percent(opts.tmux),
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

local function park_tab(index)
  local tab = state.tabs[index]
  if not tab or tab.visible ~= true or not tab.pane_id or not pane_exists(tab.pane_id) then
    return true, nil
  end

  local session = refresh_visible_tab_session(index)
  if session then
    tab.session = session
  end
  local width = current_pane_width(tab.pane_id)
  if width then
    state.slot_width_cells = width
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

  local width, width_err = desired_slot_width(anchor_pane_id, config)
  if not width then
    return nil, width_err
  end

  local _, join_err = run_tmux({
    "join-pane",
    "-d",
    "-h",
    "-l",
    width,
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

local function swap_active_tab(index)
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
  local width = current_pane_width(current.pane_id)
  if width then
    state.slot_width_cells = width
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

function M.startup_status(config)
  local session = active_startup_session()
  if not session then
    return nil
  end

  local status = read_startup_status(session, config)
  if status and status.repl_ready ~= true and prompt_ready(session) then
    status.repl_ready = true
  end

  return status
end

function M.startup_status_authoritative(config)
  local session = active_startup_session()
  if not session then
    return nil
  end

  return read_startup_status(session, config)
end

function M.startup_status_path(config)
  local session = active_startup_session()
  if not session then
    return nil
  end

  return status_file_path(session, config)
end

function M.bridge_env(config)
  if type(config.session_kind) ~= "string" or config.session_kind == "" then
    return nil
  end

  local session = active_startup_session()
  if not session then
    return nil
  end

  local authoritative_status = M.startup_status_authoritative(config)
  if type(authoritative_status) ~= "table" then
    return nil
  end
  if authoritative_status.status ~= "ready" or authoritative_status.port == nil then
    return nil
  end
  if type(authoritative_status.auth_token) ~= "string" or authoritative_status.auth_token == "" then
    return nil
  end
  if not ping_bridge(session, authoritative_status, 150) then
    return nil
  end

  local status_path = status_file_path(session, config)
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
  local startup_status = session and M.startup_status(config or {}) or nil
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
    repl_ready = bridge_ready and startup_status and startup_status.repl_ready == true or false,
    anchor_pane_id = state.anchor_pane_id,
    parking_session_name = state.parking_session_name,
    slot_width_cells = state.slot_width_cells,
    active_index = state.active_index,
    tab_count = #state.tabs,
    tabs = tab_summaries(config),
  }
end

function M.tab_new(opts)
  if not vim.env.TMUX or vim.env.TMUX == "" then
    return nil, "ark.nvim requires Neovim to run inside tmux"
  end

  prune_dead_tabs()
  local pane_id
  if state.active_index and active_tab() and active_tab().visible == true then
    local _, index, create_err = create_hidden_tab(opts)
    if not index then
      return nil, create_err
    end

    local swapped_pane_id, swap_err = swap_active_tab(index)
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
    local pane_id, swap_err = swap_active_tab(index)
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
    local swapped_pane_id, swap_err = swap_active_tab(next_index)
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
  if not vim.env.TMUX or vim.env.TMUX == "" then
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
  state.session = nil
  state.pane_id = nil
  state.managed = false
  sync_compat_state()
end

function M.stop()
  M.stop_all()
end

function M.restart(opts)
  if not vim.env.TMUX or vim.env.TMUX == "" then
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

    local swapped_pane_id, swap_err = swap_active_tab(replacement_index)
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
