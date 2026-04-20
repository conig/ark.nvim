local session_runtime = require("ark.session_runtime")

local M = {}

local state = _G.__ark_nvim_terminal_state
if type(state) ~= "table" then
  state = {}
end

local function normalize_state(raw)
  raw = raw or {}
  raw.bufnr = type(raw.bufnr) == "number" and raw.bufnr or nil
  raw.jobid = type(raw.jobid) == "number" and raw.jobid or nil
  raw.session_id = type(raw.session_id) == "string" and raw.session_id or nil
  return raw
end

state = normalize_state(state)
_G.__ark_nvim_terminal_state = state

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function normalize_split_direction(value)
  if value == nil then
    return "horizontal"
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end

  value = value:lower()
  if value == "horizontal" or value == "split" or value == "below" then
    return "horizontal"
  end
  if value == "vertical" or value == "vsplit" or value == "right" then
    return "vertical"
  end

  return nil
end

local function managed_session_id(bufnr)
  if type(bufnr) ~= "number" or bufnr < 1 then
    return nil
  end

  return string.format("terminal__nvim_%d__buf_%d", vim.fn.getpid(), bufnr)
end

local function shellescape(value)
  return vim.fn.shellescape(tostring(value or ""))
end

local function job_running(jobid)
  if type(jobid) ~= "number" or jobid <= 0 then
    return false
  end

  local status = vim.fn.jobwait({ jobid }, 0)[1]
  return status == -1
end

local function clear_state()
  state.bufnr = nil
  state.jobid = nil
  state.session_id = nil
end

local function refresh_state()
  if type(state.bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(state.bufnr) then
    clear_state()
    return nil
  end

  if not job_running(state.jobid) then
    clear_state()
    return nil
  end

  if type(state.session_id) ~= "string" or state.session_id == "" then
    state.session_id = managed_session_id(state.bufnr)
  end

  return state
end

local function current_session()
  local current = refresh_state()
  if not current then
    return nil
  end

  return {
    backend = "terminal",
    session_id = current.session_id,
    terminal_bufnr = current.bufnr,
    terminal_jobid = current.jobid,
    terminal_pid = vim.fn.jobpid(current.jobid),
  }
end

local function visible_window(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid) then
    return winid
  end

  return nil
end

local function launcher_env(config, session_id)
  local env = {
    ARK_STATUS_DIR = config.startup_status_dir,
    ARK_NVIM_SESSION_PKG_PATH = config.session_pkg_path,
    ARK_SESSION_BACKEND = "terminal",
    ARK_SESSION_ID = session_id,
    ARK_TMUX_SOCKET = "",
    ARK_TMUX_SESSION = "",
    ARK_TMUX_PANE = "",
    TMUX = "",
    TMUX_PANE = "",
  }

  if type(config.session_lib_path) == "string" and config.session_lib_path ~= "" then
    env.ARK_NVIM_SESSION_LIB = config.session_lib_path
  end

  return env
end

local function pane_command_exports(config, session_id)
  local exports = {
    "ARK_STATUS_DIR=" .. shellescape(config.startup_status_dir),
    "ARK_NVIM_SESSION_PKG_PATH=" .. shellescape(config.session_pkg_path),
    "ARK_SESSION_BACKEND=terminal",
    "ARK_SESSION_ID=" .. shellescape(session_id),
    "ARK_TMUX_SOCKET=''",
    "ARK_TMUX_SESSION=''",
    "ARK_TMUX_PANE=''",
    "TMUX=''",
    "TMUX_PANE=''",
  }

  if type(config.session_lib_path) == "string" and config.session_lib_path ~= "" then
    table.insert(exports, "ARK_NVIM_SESSION_LIB=" .. shellescape(config.session_lib_path))
  end

  return exports
end

local function open_terminal_window(config, existing_bufnr)
  local original_win = vim.api.nvim_get_current_win()
  local direction = normalize_split_direction(config.split_direction)
  if not direction then
    return nil, nil, "invalid ark.nvim terminal.split_direction: " .. tostring(config.split_direction)
  end

  local size = tonumber(config.split_size)
  local size_prefix = size and size > 0 and (tostring(math.floor(size)) .. " ") or ""
  local position = type(config.split_position) == "string" and config.split_position ~= ""
      and config.split_position
    or "botright"
  local command = string.format("%s %s%s", position, size_prefix, direction == "vertical" and "vsplit" or "split")
  vim.cmd(command)

  local winid = vim.api.nvim_get_current_win()
  if type(existing_bufnr) == "number" and vim.api.nvim_buf_is_valid(existing_bufnr) then
    vim.api.nvim_win_set_buf(winid, existing_bufnr)
  else
    vim.cmd("enew")
  end

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false

  return winid, original_win, nil
end

local function configure_send_targets(bufnr, jobid, filetypes)
  local pid = vim.fn.jobpid(jobid)
  local slime_cfg = {
    bufnr = bufnr,
    jobid = jobid,
    pid = pid,
  }
  local terminal_cfg = {
    bufnr = bufnr,
    jobid = jobid,
  }

  vim.g.slime_target = "neovim"
  vim.g.slime_neovim_ignore_unlisted = 0
  vim.g.slime_default_config = vim.deepcopy(slime_cfg)
  vim.g.slimetree_terminal_config = vim.deepcopy(terminal_cfg)

  pcall(function()
    vim.fn["slime#targets#neovim#SlimeAddChannel"](bufnr)
  end)

  for _, source_bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(source_bufnr) and filetype_enabled(filetypes, vim.bo[source_bufnr].filetype) then
      vim.b[source_bufnr].slime_target = "neovim"
      vim.b[source_bufnr].slime_config = vim.deepcopy(slime_cfg)
      vim.b[source_bufnr].slimetree_terminal_config = vim.deepcopy(terminal_cfg)
    end
  end
end

local function start_terminal_job(config, opts, target_bufnr)
  local session_id = managed_session_id(target_bufnr)
  if not session_id then
    return nil, "failed to assign managed terminal session id"
  end

  local jobid = vim.fn.termopen({ config.launcher }, {
    cwd = vim.fn.getcwd(),
    env = launcher_env(config, session_id),
    on_exit = function(_, _code, _event)
      vim.schedule(function()
        if state.jobid == jobid then
          clear_state()
        end
      end)
    end,
  })
  if type(jobid) ~= "number" or jobid <= 0 then
    return nil, "failed to start managed terminal job"
  end

  local channel = tonumber(vim.fn.getbufvar(target_bufnr, "&channel"))
  if channel and channel > 0 then
    jobid = channel
  end

  state.bufnr = target_bufnr
  state.jobid = jobid
  state.session_id = session_id

  if opts.configure_slime then
    configure_send_targets(target_bufnr, jobid, opts.filetypes)
  end

  return jobid, nil
end

local function ensure_terminal_visible(config)
  local current = refresh_state()
  if current then
    local winid = visible_window(current.bufnr)
    if winid then
      return current.bufnr, current.jobid, nil
    end

    local _, original_win, err = open_terminal_window(config, current.bufnr)
    if not original_win then
      return nil, nil, err
    end
    pcall(vim.api.nvim_set_current_win, original_win)
    return current.bufnr, current.jobid, nil
  end

  local _, original_win, err = open_terminal_window(config, nil)
  if not original_win then
    return nil, nil, err
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local jobid, job_err = start_terminal_job(config, {
    configure_slime = false,
    filetypes = {},
  }, bufnr)
  pcall(vim.api.nvim_set_current_win, original_win)
  if not jobid then
    return nil, nil, job_err
  end

  return bufnr, jobid, nil
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
    ARK_SESSION_BACKEND = "terminal",
    ARK_SESSION_ID = session.session_id,
    ARK_SESSION_STATUS_FILE = status_path,
    ARK_SESSION_TIMEOUT_MS = tostring(config.session_timeout_ms or 1000),
  }
end

local function startup_snapshot(config, snapshot_opts)
  config = config or {}
  snapshot_opts = snapshot_opts or {}

  local session = current_session()
  if not session then
    return nil
  end

  local status_path = session_runtime.status_file_path(config, session.session_id)
  local authoritative_status = status_path and session_runtime.read_status_file(status_path) or nil
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
      bridge_ready = session_runtime.ping_bridge(session, authoritative_status, timeout_ms)
    end
  end

  return {
    session = vim.deepcopy(session),
    status_path = status_path,
    startup_status_path = status_path,
    startup_status = authoritative_status and vim.deepcopy(authoritative_status) or nil,
    authoritative_status = authoritative_status and vim.deepcopy(authoritative_status) or nil,
    bridge_ready = bridge_ready,
    cmd_env = bridge_ready and bridge_env_payload(config, session, status_path) or nil,
  }
end

local function windows_for_buffer(bufnr)
  local wins = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      wins[#wins + 1] = winid
    end
  end
  return wins
end

local function close_terminal_windows(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, winid in ipairs(windows_for_buffer(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      if #vim.api.nvim_list_wins() <= 1 then
        vim.api.nvim_set_current_win(winid)
        vim.cmd("enew")
      else
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
  end

  if vim.api.nvim_buf_is_valid(bufnr) and visible_window(bufnr) == nil then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

function M.pane_command(config)
  local session_id = state.session_id or "ark-terminal-session"
  return "export " .. table.concat(pane_command_exports(config, session_id), " ")
    .. "; exec "
    .. shellescape(config.launcher)
end

function M.session()
  local session = current_session()
  return session and vim.deepcopy(session) or nil
end

function M.session_id(session)
  if type(session) ~= "table" then
    return nil
  end

  return type(session.session_id) == "string" and session.session_id or nil
end

function M.startup_snapshot(config, snapshot_opts)
  return startup_snapshot(config, snapshot_opts)
end

function M.startup_status(config)
  local snapshot = startup_snapshot(config, {
    validate_bridge = false,
  })
  return snapshot and snapshot.startup_status or nil
end

function M.startup_status_authoritative(config)
  local snapshot = startup_snapshot(config, {
    validate_bridge = false,
  })
  return snapshot and snapshot.authoritative_status or nil
end

function M.startup_status_path(config)
  local snapshot = startup_snapshot(config, {
    validate_bridge = false,
  })
  return snapshot and snapshot.startup_status_path or nil
end

function M.bridge_env(config, snapshot)
  local current = type(snapshot) == "table" and snapshot or startup_snapshot(config, {
    validate_bridge = false,
  })
  return current and current.cmd_env or nil
end

function M.send_text(text)
  local session = current_session()
  if not session or type(session.terminal_jobid) ~= "number" then
    return nil, "ark.nvim has no active managed terminal"
  end

  if type(text) ~= "string" or text == "" then
    return nil, "ark.nvim send_text() requires non-empty text"
  end

  local ok, err = pcall(vim.api.nvim_chan_send, session.terminal_jobid, text .. "\n")
  if not ok then
    return nil, tostring(err)
  end

  return true, nil
end

function M.status(config)
  local session = current_session()
  local snapshot = session and startup_snapshot(config or {}, {
    validate_bridge = true,
  }) or nil
  local startup_status = snapshot and snapshot.startup_status or nil
  local bridge_ready = snapshot and snapshot.bridge_ready == true or false
  local winid = session and visible_window(session.terminal_bufnr) or nil

  return {
    inside_tmux = type(vim.env.TMUX) == "string" and vim.env.TMUX ~= "",
    managed = session ~= nil,
    visible = winid ~= nil,
    window_id = winid,
    terminal_bufnr = session and session.terminal_bufnr or nil,
    terminal_jobid = session and session.terminal_jobid or nil,
    terminal_pid = session and session.terminal_pid or nil,
    session = session,
    backend = "terminal",
    session_id = session and session.session_id or nil,
    startup_status = startup_status,
    startup_status_path = snapshot and snapshot.startup_status_path or nil,
    bridge_ready = bridge_ready,
    repl_ready = bridge_ready and startup_status and startup_status.repl_ready == true or false,
  }
end

function M.start(opts)
  local config = opts.terminal or {}
  local bufnr, jobid, err = ensure_terminal_visible(config)
  if not bufnr then
    return nil, err
  end

  if opts.configure_slime then
    configure_send_targets(bufnr, jobid, opts.filetypes)
  end

  return tostring(bufnr), nil
end

function M.stop()
  local current = refresh_state()
  if not current then
    clear_state()
    return
  end

  local bufnr = current.bufnr
  local jobid = current.jobid
  clear_state()

  if job_running(jobid) then
    pcall(vim.fn.jobstop, jobid)
  end

  close_terminal_windows(bufnr)
end

function M.restart(opts)
  M.stop()
  return M.start(opts)
end

return M
