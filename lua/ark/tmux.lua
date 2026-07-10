local session_runtime = require("ark.session_runtime")
local console_frontend = require("ark.console_frontend")
local uv = vim.uv or vim.loop

local M = {}
local prompt_ready_cache = {}
local PROMPT_READY_CACHE_TTL_MS = 100
local FAST_TAB_PRUNE_TTL_MS = 1000

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

local function tmux_command(args)
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
  return command
end

local function run_tmux(args)
  local command = tmux_command(args)
  local output = vim.fn.system(command)
  if vim.v.shell_error ~= 0 then
    return nil, trim(output)
  end

  return trim(output), nil
end

local function start_tmux(args, job_opts)
  local command = tmux_command(args)
  job_opts = job_opts or { detach = true }
  local ok, job_id = pcall(vim.fn.jobstart, command, job_opts)
  if not ok then
    return nil, tostring(job_id)
  end
  if type(job_id) ~= "number" or job_id <= 0 then
    return nil, "failed to start tmux command"
  end

  return true, nil
end

local function strip_ansi(text)
  return (text or ""):gsub("\27%[[0-9;]*[%a]", "")
end

local function shell_join(args)
  local escaped = {}
  for _, arg in ipairs(args or {}) do
    escaped[#escaped + 1] = vim.fn.shellescape(tostring(arg))
  end
  return table.concat(escaped, " ")
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if type(source) == "string" and source:sub(1, 1) == "@" then
    local path = vim.fs.normalize(source:sub(2))
    local lua_dir = vim.fs.dirname(vim.fs.dirname(path))
    local root = vim.fs.dirname(lua_dir)
    if type(root) == "string" and root ~= "" then
      return root
    end
  end

  return vim.fn.getcwd()
end

local function lua_literal(value)
  return vim.inspect(value)
end

local popup_temp_seq = 0

local function popup_temp_path(suffix)
  popup_temp_seq = popup_temp_seq + 1
  local tmpdir = vim.env.TMPDIR
  if type(tmpdir) ~= "string" or tmpdir == "" then
    tmpdir = "/tmp"
  end
  tmpdir = tmpdir:gsub("/+$", "")

  local nonce = uv and type(uv.hrtime) == "function" and uv.hrtime() or monotonic_ms()
  return vim.fs.normalize(
    string.format("%s/ark-nvim-popup-%s-%s-%s%s", tmpdir, tostring(vim.fn.getpid()), tostring(nonce), tostring(popup_temp_seq), suffix or "")
  )
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

local function parse_positive_integer(value)
  local number = tonumber(value)
  if not number or number <= 0 then
    return nil
  end

  return math.floor(number)
end

local function tmux_format_integer(args)
  local output = run_tmux(args)
  return parse_positive_integer(output)
end

local function popup_available_width(target_client, target)
  local width
  if type(target_client) == "string" and target_client ~= "" then
    width = tmux_format_integer({ "display-message", "-p", "-c", target_client, "#{client_width}" })
  end
  if width then
    return width
  end

  if type(target) == "string" and target ~= "" then
    width = tmux_format_integer({ "display-message", "-p", "-t", target, "#{window_width}" })
  end
  if width then
    return width
  end

  if type(target) == "string" and target ~= "" then
    width = tmux_format_integer({ "display-message", "-p", "-t", target, "#{pane_width}" })
  end

  return width
end

local function help_popup_content_width(lines, title)
  local width = 0
  for _, line in ipairs(lines or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(strip_ansi(line or ""):gsub("%s+$", "")))
  end

  if type(title) == "string" and title ~= "" then
    width = math.max(width, vim.fn.strdisplaywidth(title))
  end

  return width
end

local function help_popup_width(lines, title, opts, target_client, target)
  if opts.width ~= nil and opts.width ~= "auto" then
    return tostring(opts.width)
  end

  local available = popup_available_width(target_client, target)
  local max_width = available and math.floor(available * 0.9) or nil
  local min_width = parse_positive_integer(opts.min_width) or 40
  if max_width then
    min_width = math.min(min_width, max_width)
  end

  local desired = help_popup_content_width(lines, title) + 4
  desired = math.max(min_width, desired)
  if max_width then
    desired = math.min(desired, max_width)
  end

  return tostring(math.max(1, desired))
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
  local keys = config.pane_width_env_keys or {}
  if #keys == 0 then
    return nil
  end

  for _, key in ipairs(keys) do
    local pct = parse_percent(vim.env[key])
    if pct then
      return pct
    end
  end

  local formats = {}
  for _, key in ipairs(keys) do
    formats[#formats + 1] = "#{" .. key .. "}"
  end

  local from_format = run_tmux({ "display-message", "-p", table.concat(formats, "\t") })
  if from_format then
    local values = vim.split(from_format, "\t", { plain = true, trimempty = false })
    for _, value in ipairs(values) do
      local pct = parse_percent(value)
      if pct then
        return pct
      end
    end
  end

  local env_out = run_tmux({ "show-environment", "-g" })
  if env_out then
    local wanted = {}
    for _, key in ipairs(keys) do
      wanted[key] = true
    end

    for line in (env_out .. "\n"):gmatch("(.-)\n") do
      local key, raw_value = line:match("^([^=]+)=([^\r\n]+)$")
      if key and wanted[key] then
        local pct = parse_percent(raw_value)
        if pct then
          return pct
        end
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
  if type(explicit_anchor) == "string" and explicit_anchor ~= "" then
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

local function attached_client_for_pane(pane_id)
  if type(pane_id) ~= "string" or pane_id == "" then
    return nil
  end

  local session_name = run_tmux({ "display-message", "-p", "-t", pane_id, "#{session_name}" })
  if type(session_name) ~= "string" or session_name == "" then
    return nil
  end

  local clients = run_tmux({ "list-clients", "-F", "#{client_name}\t#{client_session}" })
  if type(clients) ~= "string" or clients == "" then
    return nil
  end

  for line in (clients .. "\n"):gmatch("(.-)\n") do
    local client_name, client_session = line:match("^([^\t]+)\t([^\t]+)$")
    if client_name and client_session == session_name then
      return client_name
    end
  end

  return nil
end

local function tmux_context_available()
  return (type(vim.env.ARK_TMUX_SOCKET) == "string" and vim.env.ARK_TMUX_SOCKET ~= "")
    or (type(vim.env.TMUX) == "string" and vim.env.TMUX ~= "")
end

local function resolve_popup_target(opts)
  opts = opts or {}
  local target = type(opts.target) == "string" and opts.target ~= "" and opts.target or nil
  if not target or not pane_exists(target) then
    target = state.anchor_pane_id
  end
  if not target or not pane_exists(target) then
    local current, current_err = current_tmux_pane()
    if not current then
      return nil, current_err
    end
    target = current
  end

  return target, nil
end

local function popup_display_args(opts)
  opts = opts or {}
  local args = {
    "display-popup",
    "-E",
    "-w",
    tostring(opts.width),
    "-h",
    tostring(opts.height),
    "-x",
    "C",
    "-y",
    "C",
  }

  if opts.border == false then
    args[#args + 1] = "-B"
  end
  if opts.border ~= false and type(opts.border_lines) == "string" and opts.border_lines ~= "" then
    vim.list_extend(args, { "-b", opts.border_lines })
  end
  if type(opts.style) == "string" and opts.style ~= "" then
    vim.list_extend(args, { "-s", opts.style })
  end
  if opts.border ~= false and type(opts.border_style) == "string" and opts.border_style ~= "" then
    vim.list_extend(args, { "-S", opts.border_style })
  end

  for _, env in ipairs(opts.env or {}) do
    vim.list_extend(args, { "-e", env })
  end

  if type(opts.target_client) == "string" and opts.target_client ~= "" then
    vim.list_extend(args, { "-c", opts.target_client })
  else
    vim.list_extend(args, { "-t", opts.target })
  end

  if type(opts.title) == "string" and opts.title ~= "" then
    vim.list_extend(args, { "-T", opts.title })
  end

  args[#args + 1] = opts.command
  return args
end

local function standalone_console_context()
  return vim.g.ark_console_standalone == true or vim.env.ARK_NVIM_CONSOLE_STANDALONE == "1"
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

local function session_id(session)
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

  return table.concat({
    encode_status_component(session.tmux_socket),
    encode_status_component(session.tmux_session),
    encode_status_component(session.tmux_pane),
  }, "__")
end

local function startup_status_path(session, config)
  return session_runtime.status_file_path(config or {}, session_id(session))
end

local function nvim_console_socket(status)
  local socket = type(status) == "table" and status.nvim_console_rpc_socket or nil
  if type(socket) ~= "string" or socket == "" then
    return nil
  end

  return socket
end

local function nvim_console_status(config, session)
  config = config or {}
  local current_session_id = session_id(session)
  local exact_path = startup_status_path(session, config)
  local exact_status = exact_path and session_runtime.read_status_file(exact_path) or nil
  if nvim_console_socket(exact_status) then
    return exact_status
  end

  local root = session_runtime.status_root(config)
  local paths = vim.fn.glob(root .. "/*.json", false, true)
  local live_console_statuses = {}
  for _, path in ipairs(paths) do
    local status = session_runtime.read_status_file(path)
    if type(status) == "table" and status.nvim_console == true and nvim_console_socket(status) then
      if type(current_session_id) == "string"
        and current_session_id ~= ""
        and status.nvim_console_session_id == current_session_id
      then
        return status
      end
      live_console_statuses[#live_console_statuses + 1] = status
    end
  end

  if #live_console_statuses == 1 then
    return live_console_statuses[1]
  end

  return exact_status
end

local function bridge_session(session)
  return {
    backend = "tmux",
    session_id = session_id(session) or "",
    tmux_socket = type(session) == "table" and session.tmux_socket or "",
    tmux_session = type(session) == "table" and session.tmux_session or "",
    tmux_pane = type(session) == "table" and session.tmux_pane or "",
  }
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

  local current_session_id = session_id(session)

  return {
    ARK_SESSION_KIND = config.session_kind,
    ARK_SESSION_BACKEND = "tmux",
    ARK_SESSION_ID = current_session_id or "",
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

local function prune_dead_tabs(opts)
  opts = opts or {}
  local max_age_ms = tonumber(opts.max_age_ms)
  if max_age_ms and max_age_ms > 0 and type(state.last_prune_ms) == "number" then
    if monotonic_ms() - state.last_prune_ms < max_age_ms then
      return
    end
  end

  state.last_prune_ms = monotonic_ms()
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

local function list_window_panes(target)
  local output, err = run_tmux({
    "list-panes",
    "-t",
    target,
    "-F",
    "#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{window_width}\t#{window_height}",
  })
  if not output then
    return nil, "failed to list tmux panes: " .. tostring(err or "unknown")
  end

  local panes = {}
  for line in (output .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      local pane_id, left, top, width, height, window_width_value, window_height_value =
        line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
      left = tonumber(left)
      top = tonumber(top)
      width = tonumber(width)
      height = tonumber(height)
      window_width_value = tonumber(window_width_value)
      window_height_value = tonumber(window_height_value)
      if pane_id and left and top and width and height and window_width_value and window_height_value then
        panes[#panes + 1] = {
          pane_id = pane_id,
          left = left,
          top = top,
          width = width,
          height = height,
          window_width = window_width_value,
          window_height = window_height_value,
        }
      end
    end
  end

  return panes, nil
end

local function find_listed_pane(panes, pane_id)
  for _, pane in ipairs(panes or {}) do
    if pane.pane_id == pane_id then
      return pane
    end
  end
  return nil
end

local function panes_share_column(a, b)
  return a and b and a.left == b.left and a.width == b.width
end

local function panes_share_row(a, b)
  return a and b and a.top == b.top and a.height == b.height
end

local function pane_spans_window_height(pane)
  return pane and pane.top == 0 and pane.height >= (pane.window_height - 1)
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

local function resolve_pane_layout_from_size(config, width, height)
  local layout_name = normalize_pane_layout(config.pane_layout)
  if not layout_name then
    return nil, "invalid ark.nvim tmux.pane_layout: " .. tostring(config.pane_layout)
  end

  if layout_name ~= "auto" then
    return pane_layout(layout_name), nil
  end

  width = tonumber(width)
  height = tonumber(height)
  if not width or width <= 0 then
    return nil, "failed to resolve tmux window width"
  end
  if not height or height <= 0 then
    return nil, "failed to resolve tmux window height"
  end

  local stacked_max_width = tonumber(config.stacked_max_width)
  if stacked_max_width and stacked_max_width > 0 and width <= stacked_max_width then
    return pane_layout("stacked"), nil
  end

  if height > width then
    return pane_layout("stacked"), nil
  end

  return pane_layout("side_by_side"), nil
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
  local panes = list_window_panes(pane_id)
  local active = panes and find_listed_pane(panes, pane_id) or nil
  if active then
    for _, pane in ipairs(panes) do
      if pane.pane_id ~= pane_id and panes_share_column(active, pane) then
        return pane_layout("stacked"), nil
      end
    end

    for _, pane in ipairs(panes) do
      if pane.pane_id ~= pane_id and panes_share_row(active, pane) then
        return pane_layout("side_by_side"), nil
      end
    end
  end

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

local function existing_side_split_target_from_panes(panes, anchor_pane_id)
  local anchor = find_listed_pane(panes, anchor_pane_id)
  if not anchor or #panes < 2 or not pane_spans_window_height(anchor) then
    return nil
  end

  local leftmost = anchor.left
  local target = nil
  for _, pane in ipairs(panes) do
    if pane_spans_window_height(pane) then
      if pane.left < leftmost then
        leftmost = pane.left
      end
      if pane.left > anchor.left and (not target or pane.left < target.left) then
        target = pane
      end
    end
  end

  if target then
    return target.pane_id
  end

  if anchor.left > leftmost then
    return anchor.pane_id
  end

  return nil
end

local function existing_side_split_target(anchor_pane_id)
  local panes = list_window_panes(anchor_pane_id)
  if not panes then
    return nil
  end

  return existing_side_split_target_from_panes(panes, anchor_pane_id)
end

local function visible_pane_placement(anchor_pane_id, config)
  local panes, panes_err = list_window_panes(anchor_pane_id)
  if not panes then
    return nil, panes_err
  end

  local anchor = find_listed_pane(panes, anchor_pane_id)
  if not anchor then
    return nil, "failed to find tmux anchor pane: " .. tostring(anchor_pane_id)
  end

  local layout, layout_err = resolve_pane_layout_from_size(config, anchor.window_width, anchor.window_height)
  if not layout then
    return nil, layout_err
  end

  local placement = {
    layout = layout,
    target_pane_id = anchor_pane_id,
    before = false,
    percent = pane_percent_for_layout(config, layout.name),
  }

  if layout.name == "side_by_side" then
    local side_target = existing_side_split_target_from_panes(panes, anchor_pane_id)
    if side_target then
      placement.layout = pane_layout("stacked")
      placement.target_pane_id = side_target
      placement.before = true
      placement.percent = "50"
    end
  end

  return placement, nil
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

local function desired_slot_size(anchor_pane_id, config, layout, percent)
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

  local pct = tonumber(percent or pane_percent_for_layout(config, layout.name)) or tonumber(config.pane_percent) or 33
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

  local placement, placement_err = visible_pane_placement(anchor_pane_id, opts.tmux)
  if not placement then
    return nil, nil, placement_err
  end

  local args = { "split-window" }
  if placement.before then
    args[#args + 1] = "-b"
  end
  vim.list_extend(args, {
    placement.layout.split_flag,
    "-l",
    placement.percent .. "%",
    "-d",
    "-P",
    "-F",
    "#{pane_id}\n#{socket_path}\n#{session_name}",
    "-t",
    placement.target_pane_id,
    M.pane_command(opts.tmux),
  })

  local output, split_err = run_tmux(args)
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

  local placement, placement_err = visible_pane_placement(anchor_pane_id, config)
  if not placement then
    return nil, placement_err
  end

  local size, size_err = desired_slot_size(placement.target_pane_id, config, placement.layout, placement.percent)
  if not size then
    return nil, size_err
  end

  local args = { "join-pane", "-d" }
  if placement.before then
    args[#args + 1] = "-b"
  end
  vim.list_extend(args, {
    placement.layout.split_flag,
    "-l",
    size,
    "-s",
    tab.pane_id,
    "-t",
    placement.target_pane_id,
  })

  local _, join_err = run_tmux(args)
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

  update_active_index(index)
  return target.pane_id, nil
end

local function active_startup_session()
  prune_dead_tabs()
  local current = active_tab()
  if not current or current.visible ~= true or not current.pane_id or not pane_exists(current.pane_id) then
    if standalone_console_context() then
      return M.session()
    end
    return nil
  end

  return M.session()
end

function M.pane_command(config)
  local command, command_err = console_frontend.shell_command(config, "tmux", nil)
  if not command then
    return "printf "
      .. vim.fn.shellescape("ark.nvim: " .. tostring(command_err) .. "\n")
      .. " >&2; sleep 5"
  end

  local exports = {
    "ARK_NVIM_LAUNCHER=" .. vim.fn.shellescape(config.launcher),
    "ARK_NVIM_CONSOLE_FRONTEND=" .. vim.fn.shellescape(config.console_frontend or "raw"),
    "ARK_NVIM_MANAGED_PANE=1",
    "ARK_NVIM_PARENT_NVIM=" .. vim.fn.shellescape(vim.v.progpath or "nvim"),
    "ARK_NVIM_PARENT_SERVER=" .. vim.fn.shellescape(session_runtime.parent_server(config)),
    "ARK_STATUS_DIR=" .. vim.fn.shellescape(config.startup_status_dir),
    "ARK_NVIM_SESSION_PKG_PATH=" .. vim.fn.shellescape(config.session_pkg_path),
  }

  if type(config.lsp_bin) == "string" and config.lsp_bin ~= "" then
    table.insert(exports, "ARK_NVIM_LSP_BIN=" .. vim.fn.shellescape(config.lsp_bin))
  end

  if type(config.session_lib_path) == "string" and config.session_lib_path ~= "" then
    table.insert(exports, "ARK_NVIM_SESSION_LIB=" .. vim.fn.shellescape(config.session_lib_path))
  end

  return "export " .. table.concat(exports, " ")
    .. "; exec "
    .. command
end

function M.session()
  prune_dead_tabs()
  local current = active_tab()
  if not current or current.visible ~= true or not pane_exists(current.pane_id) then
    if standalone_console_context() then
      local session = current_session()
      return session and vim.deepcopy(session) or nil
    end
    return nil
  end

  local session = refresh_visible_tab_session(state.active_index)
  if session then
    update_active_index(state.active_index)
  end
  return session and vim.deepcopy(session) or nil
end

function M.session_id(session)
  return session_id(session)
end

function M.startup_snapshot(config, snapshot_opts)
  config = config or {}
  snapshot_opts = snapshot_opts or {}

  local session = active_startup_session()
  if not session then
    return nil
  end

  local request_session = bridge_session(session)
  local status_path = startup_status_path(session, config)
  local authoritative_status = status_path
    and session_runtime.read_status_file(status_path, { require_live_pid = true })
    or nil
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
      bridge_ready = session_runtime.ping_bridge(request_session, authoritative_status, timeout_ms)
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

local function nvim_console_send(config, session, text)
  if console_frontend.normalize(config and config.console_frontend) ~= "nvim-console" then
    return nil
  end

  local status = nvim_console_status(config or {}, session)
  local socket = nvim_console_socket(status)
  if not socket then
    return nil
  end

  local connect_ok, chan = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
  if connect_ok and type(chan) == "number" and chan > 0 then
    local ok, result = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return _G.__ark_console_rpc_send(...)", {
      text,
    })
    pcall(vim.fn.chanclose, chan)
    if ok and result == "ok" then
      return true, nil
    end
    if ok then
      return nil, "nvim-console RPC send returned unexpected response: " .. tostring(result)
    end
    return nil, tostring(result)
  end

  local nvim_bin = vim.env.ARK_NVIM_CONSOLE_NVIM or vim.v.progpath or "nvim"
  local expr = "v:lua.__ark_console_rpc_send(" .. vim.fn.string(text) .. ")"
  local output = vim.fn.system({
    nvim_bin,
    "--server",
    socket,
    "--remote-expr",
    expr,
  })
  if vim.v.shell_error ~= 0 then
    return nil, vim.trim(output)
  end
  if vim.trim(output) ~= "ok" then
    return nil, "nvim-console RPC send returned unexpected response: " .. vim.trim(output)
  end

  return true, nil
end

function M.console_ready(config)
  local session = active_startup_session()
  if not session then
    return false
  end

  local status = nvim_console_status(config or {}, session)
  return type(status) == "table"
    and status.nvim_console_running == true
    and nvim_console_socket(status) ~= nil
end

function M.send_text(config_or_text, maybe_text)
  local config = type(config_or_text) == "table" and config_or_text or {}
  local text = maybe_text
  if text == nil then
    text = config_or_text
  end

  local session = active_startup_session()
  if not session or type(session.tmux_pane) ~= "string" or session.tmux_pane == "" then
    return nil, "ark.nvim has no active managed pane"
  end

  if type(text) ~= "string" or text == "" then
    return nil, "ark.nvim send_text() requires non-empty text"
  end

  local console_ok, console_err = nvim_console_send(config, session, text)
  if console_ok then
    return true, nil
  end
  if console_err and console_err ~= "" then
    return nil, console_err
  end
  if console_frontend.normalize(config.console_frontend) == "nvim-console" then
    return nil, "managed nvim-console RPC endpoint is not ready"
  end

  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end

  local buffer_name = "ark.nvim-send-" .. tostring(monotonic_ms())
  local _, set_err = run_tmux({ "set-buffer", "-b", buffer_name, text })
  if set_err then
    return nil, set_err
  end

  local _, err = run_tmux({ "paste-buffer", "-d", "-b", buffer_name, "-t", session.tmux_pane })
  if err then
    return nil, err
  end

  return true, nil
end

local function help_popup_bootstrap_lines(help)
  help = type(help) == "table" and help or {}
  local initial = type(help.initial) == "table" and help.initial or {}
  local references = type(initial.references) == "table" and initial.references or {}
  local topic = type(initial.topic) == "string" and initial.topic or ""
  local references_json = vim.json.encode(references)
  local rpc_name = type(help.rpc_name) == "string" and help.rpc_name ~= "" and help.rpc_name or "__ark_help_popup_backend"
  local server = type(help.server) == "string" and help.server or ""
  local backend_id = type(help.backend_id) == "string" and help.backend_id or ""
  local rpc_source = table.concat({
    "local rpc_name, backend_id, method, args = ...",
    "local fn = _G[rpc_name]",
    "if type(fn) ~= 'function' then",
    "  return { ok = false, err = 'ArkHelp popup backend RPC is not registered' }",
    "end",
    "return fn(backend_id, method, args)",
  }, "\n")

  return {
    "local ns = vim.api.nvim_create_namespace('ArkHelpPopup')",
    "local references = vim.json.decode(" .. lua_literal(references_json) .. ") or {}",
    "local current_topic = " .. lua_literal(topic),
    "local back_stack = {}",
    "local forward_stack = {}",
    "local server = " .. lua_literal(server),
    "local backend_id = " .. lua_literal(backend_id),
    "local rpc_name = " .. lua_literal(rpc_name),
    "local rpc_source = " .. lua_literal(rpc_source),
    "local chan = nil",
    "vim.b.ark_help_topic = current_topic",
    "local function style_links()",
    "  local ok, underlined = pcall(vim.api.nvim_get_hl, 0, { name = 'Underlined', link = false })",
    "  local fg = ok and type(underlined) == 'table' and underlined.fg or nil",
    "  vim.api.nvim_set_hl(0, 'ArkHelpReference', { fg = fg or 0x61afef, underline = true, bold = true })",
    "end",
    "local function apply_reference_highlights(next_references)",
    "  references = type(next_references) == 'table' and next_references or {}",
    "  vim.b.ark_help_references = references",
    "  vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)",
    "  style_links()",
    "  for _, reference in ipairs(references) do",
    "    local line = tonumber(reference.line)",
    "    local start_col = tonumber(reference.start_col)",
    "    local end_col = tonumber(reference.end_col)",
    "    if line and start_col and end_col and line > 0 and end_col > start_col then",
    "      pcall(vim.api.nvim_buf_set_extmark, 0, ns, line - 1, start_col, {",
    "        end_col = end_col,",
    "        hl_group = 'ArkHelpReference',",
    "        priority = 320,",
    "      })",
    "    end",
    "  end",
    "end",
    "local function connect()",
    "  if type(chan) == 'number' and chan > 0 then",
    "    return chan, nil",
    "  end",
    "  if server == '' then",
    "    return nil, 'ArkHelp popup link backend is not configured'",
    "  end",
    "  local ok, result = pcall(vim.fn.sockconnect, 'pipe', server, { rpc = true })",
    "  if not ok or type(result) ~= 'number' or result <= 0 then",
    "    return nil, 'failed to connect ArkHelp popup to ' .. tostring(server) .. ': ' .. tostring(result)",
    "  end",
    "  chan = result",
    "  return chan, nil",
    "end",
    "local function request(method, args)",
    "  local rpc_chan, connect_err = connect()",
    "  if not rpc_chan then",
    "    return nil, connect_err",
    "  end",
    "  local ok, response = pcall(vim.rpcrequest, rpc_chan, 'nvim_exec_lua', rpc_source, { rpc_name, backend_id, method, args or {} })",
    "  if not ok then",
    "    return nil, tostring(response)",
    "  end",
    "  if type(response) ~= 'table' then",
    "    return nil, 'invalid ArkHelp popup backend response'",
    "  end",
    "  if response.ok == false then",
    "    return nil, tostring(response.err or 'ArkHelp popup backend request failed')",
    "  end",
    "  return response.value, nil",
    "end",
    "local function set_page(page, target)",
    "  if type(page) ~= 'table' then",
    "    return nil, 'invalid ArkHelp page response'",
    "  end",
    "  local lines = type(page.lines) == 'table' and page.lines or { '' }",
    "  if #lines == 0 then",
    "    lines = { '' }",
    "  end",
    "  vim.bo.readonly = false",
    "  vim.bo.modifiable = true",
    "  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)",
    "  vim.bo.modifiable = false",
    "  vim.bo.readonly = true",
    "  apply_reference_highlights(page.references)",
    "  current_topic = type(page.topic) == 'string' and page.topic ~= '' and page.topic or target",
    "  vim.b.ark_help_topic = current_topic",
    "  pcall(vim.api.nvim_win_set_cursor, 0, { 1, 0 })",
    "  return true, nil",
    "end",
    "local function reference_under_cursor()",
    "  local cursor = vim.api.nvim_win_get_cursor(0)",
    "  local line = cursor[1]",
    "  local col = cursor[2]",
    "  for _, reference in ipairs(references or {}) do",
    "    if reference.line == line and col >= reference.start_col and col < reference.end_col then",
    "      return reference",
    "    end",
    "  end",
    "  return nil",
    "end",
    "local function follow_reference()",
    "  local reference = reference_under_cursor()",
    "  if not reference then",
    "    return",
    "  end",
    "  local section_line = tonumber(reference.section_line)",
    "  if section_line and section_line > 0 then",
    "    pcall(vim.api.nvim_win_set_cursor, 0, { section_line, 0 })",
    "    return",
    "  end",
    "  if type(reference.target) ~= 'string' or reference.target == '' then",
    "    return",
    "  end",
    "  local page, err = request('page', { reference.target })",
    "  if not page then",
    "    vim.notify(tostring(err or 'failed to follow ArkHelp link'), vim.log.levels.WARN, { title = 'ark.nvim' })",
    "    return",
    "  end",
    "  local previous = current_topic",
    "  local ok, set_err = set_page(page, reference.target)",
    "  if not ok then",
    "    vim.notify(tostring(set_err or 'failed to render ArkHelp link'), vim.log.levels.WARN, { title = 'ark.nvim' })",
    "    return",
    "  end",
    "  if type(previous) == 'string' and previous ~= '' and previous ~= current_topic then",
    "    back_stack[#back_stack + 1] = previous",
    "    forward_stack = {}",
    "  end",
    "end",
    "local function history_back()",
    "  local target = back_stack[#back_stack]",
    "  if type(target) ~= 'string' or target == '' then",
    "    return",
    "  end",
    "  local page, err = request('page', { target })",
    "  if not page then",
    "    vim.notify(tostring(err or 'failed to open previous ArkHelp page'), vim.log.levels.WARN, { title = 'ark.nvim' })",
    "    return",
    "  end",
    "  local previous = current_topic",
    "  local ok, set_err = set_page(page, target)",
    "  if not ok then",
    "    vim.notify(tostring(set_err or 'failed to render previous ArkHelp page'), vim.log.levels.WARN, { title = 'ark.nvim' })",
    "    return",
    "  end",
    "  back_stack[#back_stack] = nil",
    "  if type(previous) == 'string' and previous ~= '' and previous ~= current_topic then",
    "    forward_stack[#forward_stack + 1] = previous",
    "  end",
    "end",
    "local function history_forward()",
    "  local target = forward_stack[#forward_stack]",
    "  if type(target) ~= 'string' or target == '' then",
    "    return",
    "  end",
    "  local page, err = request('page', { target })",
    "  if not page then",
    "    vim.notify(tostring(err or 'failed to open next ArkHelp page'), vim.log.levels.WARN, { title = 'ark.nvim' })",
    "    return",
    "  end",
    "  local previous = current_topic",
    "  local ok, set_err = set_page(page, target)",
    "  if not ok then",
    "    vim.notify(tostring(set_err or 'failed to render next ArkHelp page'), vim.log.levels.WARN, { title = 'ark.nvim' })",
    "    return",
    "  end",
    "  forward_stack[#forward_stack] = nil",
    "  if type(previous) == 'string' and previous ~= '' and previous ~= current_topic then",
    "    back_stack[#back_stack + 1] = previous",
    "  end",
    "end",
    "vim.keymap.set('n', '<CR>', follow_reference, { buffer = 0, nowait = true, silent = true })",
    "vim.keymap.set('n', 'H', history_back, { buffer = 0, nowait = true, silent = true })",
    "vim.keymap.set('n', 'L', history_forward, { buffer = 0, nowait = true, silent = true })",
    "vim.api.nvim_create_autocmd('VimLeavePre', {",
    "  once = true,",
    "  callback = function()",
    "    pcall(request, 'dispose', {})",
    "    if type(chan) == 'number' then",
    "      pcall(vim.fn.chanclose, chan)",
    "    end",
    "  end,",
    "})",
    "apply_reference_highlights(references)",
  }
end

function M.help_popup(_config, text, opts)
  opts = opts or {}

  if not tmux_context_available() then
    return nil, "tmux popup requires Neovim to run inside tmux"
  end

  if type(text) ~= "string" or text == "" then
    return nil, "tmux popup requires non-empty help text"
  end

  local target = type(opts.target) == "string" and opts.target ~= "" and opts.target or nil
  if not target or not pane_exists(target) then
    target = state.anchor_pane_id
  end
  if not target or not pane_exists(target) then
    local current, current_err = current_tmux_pane()
    if not current then
      return nil, current_err
    end
    target = current
  end

  local path = popup_temp_path(".arkhelp")
  local script = popup_temp_path(".arkhelp-popup.sh")
  local bootstrap = nil
  local lines = vim.split(text, "\n", { plain = true })
  local write_ok, write_err = pcall(vim.fn.writefile, lines, path, "b")
  if not write_ok then
    return nil, "failed to write ArkHelp popup text: " .. tostring(write_err)
  end

  local title = type(opts.title) == "string" and opts.title or "ArkHelp"
  local viewer = type(opts.viewer) == "string" and opts.viewer ~= "" and opts.viewer or "nvim"
  local popup_command_args
  local popup_env = {}
  local cleanup_from_parent = false

  if viewer == "nvim" then
    bootstrap = popup_temp_path(".arkhelp.lua")
    local bootstrap_ok, bootstrap_err = pcall(vim.fn.writefile, help_popup_bootstrap_lines(opts.help), bootstrap, "b")
    if not bootstrap_ok then
      pcall(vim.fn.delete, path)
      return nil, "failed to write ArkHelp popup bootstrap: " .. tostring(bootstrap_err)
    end

    local nvim = type(opts.nvim) == "table" and opts.nvim or {}
    local nvim_bin = type(nvim.bin) == "string" and nvim.bin ~= "" and nvim.bin or vim.v.progpath or "nvim"
    local hide_chrome = "set laststatus=0 showtabline=0 noshowmode noruler noshowcmd | silent! set cmdheight=0"
    local close_popup_lua = table.concat({
      "lua _G.__ark_help_popup_close = function()",
      "if vim.g.__ark_help_popup_closing == 1 then return end",
      "vim.g.__ark_help_popup_closing = 1",
      "pcall(vim.fn.jobstart, { 'tmux', 'display-popup', '-C' }, { detach = true })",
      "end",
    }, " ")
    local cleanup_help_lua = table.concat({
      "lua vim.api.nvim_create_autocmd('VimLeavePre', {",
      "once = true,",
      "callback = function() pcall(vim.fn.delete, "
        .. lua_literal(path)
        .. "); pcall(vim.fn.delete, "
        .. lua_literal(bootstrap)
        .. ") end,",
      "})",
    }, " ")
    local close_popup_command =
      "lua pcall(_G.__ark_help_popup_close); vim.defer_fn(function() vim.cmd('qa!') end, 20)"
    popup_command_args = {
      nvim_bin,
      "-n",
      "-R",
      "-M",
      "--cmd",
      "let g:ark_help_popup = 1",
      "--cmd",
      "let g:ark_nvim_help_popup = 1",
      "--cmd",
      "let g:markdown_fenced_languages = ['r']",
      "--cmd",
      hide_chrome,
      "--cmd",
      close_popup_lua,
      "--cmd",
      cleanup_help_lua,
      path,
      "-c",
      hide_chrome,
      "-c",
      "setlocal buftype=nowrite bufhidden=wipe noswapfile readonly nomodifiable filetype=markdown",
      "-c",
      "runtime! syntax/markdown.vim | syntax sync fromstart",
      "-c",
      "lua pcall(vim.treesitter.start, 0, 'markdown')",
      "-c",
      "luafile " .. bootstrap,
      "-c",
      "autocmd QuitPre * lua pcall(_G.__ark_help_popup_close)",
      "-c",
      "nnoremap <buffer><silent> q <Cmd>" .. close_popup_command .. "<CR>",
      "-c",
      "stopinsert",
      "-c",
      "normal! gg0",
    }
    if type(nvim.init) == "string" and nvim.init ~= "" then
      table.insert(popup_command_args, 2, nvim.init)
      table.insert(popup_command_args, 2, "-u")
    end
    popup_env[#popup_env + 1] = "TERM=ansi"
  elseif viewer == "pager" or viewer == "less" then
    local pager = type(opts.pager) == "table" and opts.pager or {}
    local pager_bin = type(pager.bin) == "string" and pager.bin ~= "" and pager.bin or "less"
    popup_command_args = { pager_bin, "-X", "-R", path }
    cleanup_from_parent = true
  else
    pcall(vim.fn.delete, path)
    pcall(vim.fn.delete, bootstrap)
    return nil, "unsupported ArkHelp tmux popup viewer: " .. tostring(opts.viewer)
  end

  local cleanup_paths = { script, path }
  if bootstrap then
    cleanup_paths[#cleanup_paths + 1] = bootstrap
  end
  local cleanup_args = {}
  for _, cleanup_path in ipairs(cleanup_paths) do
    cleanup_args[#cleanup_args + 1] = vim.fn.shellescape(cleanup_path)
  end

  local script_lines = {
    "#!/bin/sh",
    shell_join(popup_command_args),
    "status=$?",
    "rm -f -- " .. table.concat(cleanup_args, " "),
    "exit $status",
  }
  local script_ok, script_err = pcall(vim.fn.writefile, script_lines, script, "b")
  if not script_ok then
    pcall(vim.fn.delete, path)
    pcall(vim.fn.delete, bootstrap)
    return nil, "failed to write ArkHelp popup launcher: " .. tostring(script_err)
  end
  pcall(vim.fn.setfperm, script, "rwx------")

  local target_client = attached_client_for_pane(target)
  local width = help_popup_width(lines, title, opts, target_client, target)
  local height = tostring(opts.height or "80%")

  local args = popup_display_args({
    width = width,
    height = height,
    env = popup_env,
    target = target,
    target_client = target_client,
    title = title,
    border = opts.border,
    border_lines = opts.border_lines,
    style = opts.style,
    border_style = opts.border_style,
    command = script,
  })

  local job_opts = nil
  if cleanup_from_parent then
    job_opts = {
      on_exit = function()
        pcall(vim.fn.delete, path)
        pcall(vim.fn.delete, script)
        pcall(vim.fn.delete, bootstrap)
      end,
    }
  end

  local _, popup_err = start_tmux(args, job_opts)
  if popup_err then
    pcall(vim.fn.delete, path)
    pcall(vim.fn.delete, script)
    pcall(vim.fn.delete, bootstrap)
    return nil, "failed to open tmux ArkHelp popup: " .. tostring(popup_err)
  end

  return true, nil
end

local function view_popup_bootstrap_lines(root, server, backend_id, expr)
  local rpc_source = table.concat({
    "local rpc_name, backend_id, method, args = ...",
    "local fn = _G[rpc_name]",
    "if type(fn) ~= 'function' then",
    "  return { ok = false, err = 'ArkView popup backend RPC is not registered' }",
    "end",
    "return fn(backend_id, method, args)",
  }, "\n")

  return {
    "vim.opt.rtp:prepend(" .. lua_literal(root) .. ")",
    "vim.g.ark_view_popup = 1",
    "vim.opt.laststatus = 0",
    "vim.opt.showtabline = 0",
    "vim.opt.showmode = false",
    "vim.opt.ruler = false",
    "vim.opt.showcmd = false",
    "pcall(function() vim.opt.cmdheight = 0 end)",
    "pcall(function()",
    "  local nvconfig = require('nvconfig')",
    "  if type(nvconfig.nvdash) == 'table' then",
    "    nvconfig.nvdash.load_on_startup = false",
    "  end",
    "end)",
    "local server = " .. lua_literal(server),
    "local backend_id = " .. lua_literal(backend_id),
    "local expr = " .. lua_literal(expr),
    "local rpc_name = " .. lua_literal("__ark_view_popup_backend"),
    "local rpc_source = " .. lua_literal(rpc_source),
    "local chan = nil",
    "local disposed = false",
    "local popup_closing = false",
    "local function close_popup()",
    "  if popup_closing then",
    "    return",
    "  end",
    "  popup_closing = true",
    "  pcall(vim.fn.jobstart, { 'tmux', 'display-popup', '-C' }, { detach = true })",
    "end",
    "vim.api.nvim_create_autocmd('QuitPre', {",
    "  once = true,",
    "  callback = function() close_popup() end,",
    "})",
    "local function connect()",
    "  if type(chan) == 'number' and chan > 0 then",
    "    return chan, nil",
    "  end",
    "  local ok, result = pcall(vim.fn.sockconnect, 'pipe', server, { rpc = true })",
    "  if not ok or type(result) ~= 'number' or result <= 0 then",
    "    return nil, 'failed to connect ArkView popup to ' .. tostring(server) .. ': ' .. tostring(result)",
    "  end",
    "  chan = result",
    "  return chan, nil",
    "end",
    "local function request(method, args)",
    "  local rpc_chan, connect_err = connect()",
    "  if not rpc_chan then",
    "    return nil, connect_err",
    "  end",
    "  local ok, response = pcall(vim.rpcrequest, rpc_chan, 'nvim_exec_lua', rpc_source, { rpc_name, backend_id, method, args or {} })",
    "  if not ok then",
    "    return nil, tostring(response)",
    "  end",
    "  if type(response) ~= 'table' then",
    "    return nil, 'invalid ArkView popup backend response'",
    "  end",
    "  if response.ok == false then",
    "    return nil, tostring(response.err or 'ArkView popup backend request failed')",
    "  end",
    "  return response.value, nil",
    "end",
    "local function dispose()",
    "  if disposed then",
    "    return",
    "  end",
    "  disposed = true",
    "  pcall(request, 'dispose', {})",
    "  if type(chan) == 'number' then",
    "    pcall(vim.fn.chanclose, chan)",
    "  end",
    "end",
    "local proxy = {}",
    "for _, method in ipairs({",
    "  'view_open',",
    "  'view_state',",
    "  'view_page',",
    "  'view_sort',",
    "  'view_filter',",
    "  'view_values',",
    "  'view_schema_search',",
    "  'view_profile',",
    "  'view_code',",
    "  'view_export',",
    "  'view_cell',",
    "  'view_close',",
    "  'object_children',",
    "  'object_detail',",
    "  'object_table',",
    "  'object_search',",
    "}) do",
    "  proxy[method] = function(_options, _source_bufnr, ...)",
    "    return request(method, { ... })",
    "  end",
    "end",
    "local notify = function(message, level)",
    "  vim.notify(message, level or vim.log.levels.INFO, { title = 'ark.nvim' })",
    "end",
    "local ok, opened, err = pcall(function()",
    "  return require('ark.view').open({",
    "    expr = expr,",
    "    source_bufnr = 0,",
    "    options = {},",
    "    lsp = proxy,",
    "    notify = notify,",
    "    on_close = function()",
    "      dispose()",
    "      close_popup()",
    "      vim.defer_fn(function() vim.cmd('qa!') end, 20)",
    "    end,",
    "  })",
    "end)",
    "if not ok then",
    "  notify(tostring(opened), vim.log.levels.ERROR)",
    "  dispose()",
    "  close_popup()",
    "  vim.defer_fn(function() vim.cmd('cq') end, 50)",
    "elseif not opened then",
    "  notify(tostring(err or 'failed to open ArkView'), vim.log.levels.ERROR)",
    "  dispose()",
    "  close_popup()",
    "  vim.defer_fn(function() vim.cmd('cq') end, 50)",
    "end",
  }
end

function M.view_popup(_config, server, backend_id, expr, opts)
  opts = opts or {}

  if not tmux_context_available() then
    return nil, "tmux popup requires Neovim to run inside tmux"
  end

  if type(server) ~= "string" or server == "" then
    return nil, "tmux ArkView popup requires an RPC server"
  end
  if type(backend_id) ~= "string" or backend_id == "" then
    return nil, "tmux ArkView popup requires a backend id"
  end
  if type(expr) ~= "string" or expr == "" then
    return nil, "tmux ArkView popup requires a non-empty expression"
  end

  local target, target_err = resolve_popup_target(opts)
  if not target then
    return nil, target_err
  end

  local title = type(opts.title) == "string" and opts.title or "ArkView"
  local nvim = type(opts.nvim) == "table" and opts.nvim or {}
  local nvim_bin = type(nvim.bin) == "string" and nvim.bin ~= "" and nvim.bin or vim.v.progpath or "nvim"
  local root = plugin_root()
  local script = popup_temp_path(".arkview.lua")
  local startup_buffer = popup_temp_path(".arkview-startup")
  local hide_chrome = "set laststatus=0 showtabline=0 noshowmode noruler noshowcmd shortmess+=I | silent! set cmdheight=0"
  local write_ok, write_err = pcall(vim.fn.writefile, view_popup_bootstrap_lines(root, server, backend_id, expr), script, "b")
  if not write_ok then
    return nil, "failed to write ArkView popup bootstrap: " .. tostring(write_err)
  end
  local startup_ok, startup_err = pcall(vim.fn.writefile, {}, startup_buffer, "b")
  if not startup_ok then
    pcall(vim.fn.delete, script)
    return nil, "failed to write ArkView popup startup buffer: " .. tostring(startup_err)
  end

  local nvim_args = {
    nvim_bin,
    "-n",
    "--cmd",
    hide_chrome,
    "--cmd",
    "set rtp^=" .. root,
    "--cmd",
    "let g:ark_view_popup = 1",
    "--cmd",
    "let g:ark_view_popup_server = " .. vim.fn.string(server),
    "--cmd",
    "let g:ark_view_popup_backend_id = " .. vim.fn.string(backend_id),
    startup_buffer,
    "-c",
    hide_chrome,
    "-c",
    "luafile " .. script,
  }
  if type(nvim.init) == "string" and nvim.init ~= "" then
    table.insert(nvim_args, 2, nvim.init)
    table.insert(nvim_args, 2, "-u")
  end

  local escaped_script = vim.fn.shellescape(script)
  local escaped_startup_buffer = vim.fn.shellescape(startup_buffer)
  local command_body = shell_join(nvim_args)
    .. "; status=$?; rm -f -- "
    .. escaped_script
    .. " "
    .. escaped_startup_buffer
    .. "; exit $status"
  local command = "sh -lc " .. vim.fn.shellescape(command_body)

  local target_client = attached_client_for_pane(target)
  local args = popup_display_args({
    width = tostring(opts.width or "90%"),
    height = tostring(opts.height or "90%"),
    target = target,
    target_client = target_client,
    title = title,
    border = opts.border,
    border_lines = opts.border_lines,
    style = opts.style,
    border_style = opts.border_style,
    command = command,
  })

  local _, popup_err = start_tmux(args)
  if popup_err then
    pcall(vim.fn.delete, script)
    pcall(vim.fn.delete, startup_buffer)
    return nil, "failed to open tmux ArkView popup: " .. tostring(popup_err)
  end

  return true, nil
end

function M.nvim_ui_popup(_config, server, opts)
  opts = opts or {}

  if not tmux_context_available() then
    return nil, "tmux popup requires Neovim to run inside tmux"
  end

  if type(server) ~= "string" or server == "" then
    return nil, "tmux Neovim popup requires an RPC server"
  end

  local target, target_err = resolve_popup_target(opts)
  if not target then
    return nil, target_err
  end

  local title = type(opts.title) == "string" and opts.title or "ArkView"
  local nvim = type(opts.nvim) == "table" and opts.nvim or {}
  local nvim_bin = type(nvim.bin) == "string" and nvim.bin ~= "" and nvim.bin or vim.v.progpath or "nvim"
  local command_body = shell_join({ nvim_bin, "--server", server, "--remote-ui" })
  local command = "sh -lc " .. vim.fn.shellescape(command_body)

  local target_client = attached_client_for_pane(target)
  local args = popup_display_args({
    width = tostring(opts.width or "90%"),
    height = tostring(opts.height or "90%"),
    target = target,
    target_client = target_client,
    title = title,
    border = opts.border,
    border_lines = opts.border_lines,
    style = opts.style,
    border_style = opts.border_style,
    command = command,
  })

  local _, popup_err = start_tmux(args)
  if popup_err then
    return nil, "failed to open tmux Neovim popup: " .. tostring(popup_err)
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
      startup_status_path = session and startup_status_path(session, config or {}) or nil,
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
  local current_session_id = session_id(session)
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
    backend = "tmux",
    session_id = current_session_id,
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
  prune_dead_tabs({ max_age_ms = FAST_TAB_PRUNE_TTL_MS })
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
  prune_dead_tabs({ max_age_ms = FAST_TAB_PRUNE_TTL_MS })
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
  prune_dead_tabs({ max_age_ms = FAST_TAB_PRUNE_TTL_MS })
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
