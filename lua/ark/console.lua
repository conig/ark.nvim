local lsp = require("ark.lsp")
local session_runtime = require("ark.session_runtime")

local M = {}

local prompt_ns = vim.api.nvim_create_namespace("ArkConsole")
local input_ns = vim.api.nvim_create_namespace("ArkConsoleInput")
local console_server_fn = "__ark_console_rpc_send"
local job_running
local state = _G.__ark_nvim_console_state
if type(state) ~= "table" then
  state = {
    buffers = {},
  }
end
state.buffers = type(state.buffers) == "table" and state.buffers or {}
_G.__ark_nvim_console_state = state

local function encode_status_component(value)
  return (tostring(value or ""):gsub("([^%w%._%-])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function tmux_session_id()
  if type(vim.env.TMUX) ~= "string" or vim.env.TMUX == "" then
    return nil
  end

  local output = vim.fn.systemlist({
    "tmux",
    "display-message",
    "-p",
    "#{socket_path}\n#{session_name}\n#{pane_id}",
  })
  if vim.v.shell_error ~= 0 or type(output) ~= "table" or #output < 3 then
    return nil
  end

  local socket_path = output[1]
  local session_name = output[2]
  local pane_id = output[3]
  if socket_path == "" or session_name == "" or pane_id == "" then
    return nil
  end

  return table.concat({
    encode_status_component(socket_path),
    encode_status_component(session_name),
    encode_status_component(pane_id),
  }, "__")
end

local function shell_env(config, session_id, status_path)
  local env = {
    ARK_STATUS_DIR = config.startup_status_dir,
    ARK_NVIM_SESSION_PKG_PATH = config.session_pkg_path,
    ARK_SESSION_KIND = config.session_kind or "ark",
    ARK_SESSION_BACKEND = "nvim-console",
    ARK_SESSION_ID = session_id,
    ARK_SESSION_STATUS_FILE = status_path,
    ARK_SESSION_TIMEOUT_MS = tostring(config.session_timeout_ms or 1000),
  }

  if type(config.session_lib_path) == "string" and config.session_lib_path ~= "" then
    env.ARK_NVIM_SESSION_LIB = config.session_lib_path
  end

  return env
end

local function session_id_for_buffer(bufnr)
  local tmux_id = tmux_session_id()
  if type(tmux_id) == "string" and tmux_id ~= "" then
    return tmux_id
  end

  local env_session_id = vim.env.ARK_SESSION_ID
  if type(env_session_id) == "string" and env_session_id ~= "" then
    return env_session_id
  end

  return string.format("nvim_console__nvim_%d__buf_%d", vim.fn.getpid(), bufnr)
end

local function rpc_socket_path(config, session_id)
  return vim.fs.normalize(session_runtime.status_root(config) .. "/" .. session_id .. ".sock")
end

local function merge_status_file(path, patch)
  if type(path) ~= "string" or path == "" or type(patch) ~= "table" then
    return
  end

  local payload = session_runtime.read_status_file(path) or {}
  for key, value in pairs(patch) do
    payload[key] = value
  end

  local dir = vim.fs.dirname(path)
  if type(dir) == "string" and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile({ vim.json.encode(payload) }, path)
end

local function publish_status(bufnr)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return
  end

  local rpc_socket = info.rpc_running == false and vim.NIL or info.rpc_socket
  merge_status_file(info.status_path, {
    nvim_console_last_send = info.last_send,
    nvim_console_last_send_ms = info.last_send_ms,
    nvim_console = info.closed ~= true,
    nvim_console_bufnr = bufnr,
    nvim_console_pid = vim.fn.getpid(),
    nvim_console_rpc_socket = rpc_socket,
    nvim_console_running = info.closed ~= true and job_running(info.jobid),
    nvim_console_session_id = info.session_id,
  })
end

local function start_status_publisher(bufnr)
  local timer = vim.uv.new_timer()
  if not timer then
    publish_status(bufnr)
    return nil
  end

  timer:start(0, 500, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      timer:stop()
      timer:close()
      return
    end

    publish_status(bufnr)
  end))

  return timer
end

local function strip_ansi(text)
  return (text or ""):gsub("\27%[[0-9;?;]*[%a]", "")
end

local function prompt_suffix(text)
  local patterns = {
    { pattern = "(Browse%[[0-9]+%]>%s*)$", state = "browser" },
    { pattern = "(debug>%s*)$", state = "debug" },
    { pattern = "(recover>%s*)$", state = "recover" },
    { pattern = "(%+%s*)$", state = "continuation" },
    { pattern = "(>%s*)$", state = "top-level" },
  }

  for _, candidate in ipairs(patterns) do
    local start_col, _, prompt = text:find(candidate.pattern)
    if start_col then
      return {
        state = candidate.state,
        text = (prompt or ""):gsub("%s+$", ""),
        start_col = start_col,
      }
    end
  end

  return nil
end

local function strip_prompt_suffix(text)
  local prompt = prompt_suffix(text)
  if not prompt then
    return text, nil
  end

  return text:sub(1, prompt.start_col - 1), prompt
end

local function pop_echo_line(info, line)
  local queue = type(info) == "table" and info.pending_echo_lines or nil
  if type(queue) ~= "table" or #queue == 0 then
    return false
  end

  if queue[1] ~= line then
    return false
  end

  table.remove(queue, 1)
  return true
end

local function transcript_lines_from_text(info, text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line
      :gsub("^%s*Browse%[[0-9]+%]>%s*", "")
      :gsub("^%s*debug>%s*", "")
      :gsub("^%s*recover>%s*", "")
      :gsub("^%s*[>+]%s+", "")
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" and not pop_echo_line(info, line) then
      lines[#lines + 1] = "#> " .. line
    end
  end
  return lines
end

local function prompt_label(info)
  if info.prompt_state == "continuation" then
    return "+ "
  elseif info.prompt_state == "browser" then
    return (info.prompt_text or "Browse>") .. " "
  elseif info.prompt_state == "debug" then
    return "debug> "
  elseif info.prompt_state == "recover" then
    return "recover> "
  elseif info.prompt_state == "busy" then
    return "* "
  end
  return "> "
end

local input_start_line

local function place_prompt(bufnr)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, prompt_ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, prompt_ns, input_start_line(bufnr, info), 0, {
    virt_text = { { prompt_label(info), "Question" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

input_start_line = function(bufnr, info)
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end

  if type(info.input_mark_id) == "number" then
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, input_ns, info.input_mark_id, {})
    if type(pos) == "table" and type(pos[1]) == "number" then
      info.input_start = pos[1]
      return pos[1]
    end
  end

  return math.max(0, math.min(tonumber(info.input_start) or 0, vim.api.nvim_buf_line_count(bufnr) - 1))
end

local function set_input_start(bufnr, info, line)
  line = math.max(0, math.min(tonumber(line) or 0, vim.api.nvim_buf_line_count(bufnr) - 1))
  info.input_start = line
  local opts = {
    right_gravity = false,
  }
  if type(info.input_mark_id) == "number" then
    opts.id = info.input_mark_id
  end
  info.input_mark_id = vim.api.nvim_buf_set_extmark(bufnr, input_ns, line, 0, opts)
end

local function current_input_lines(bufnr, info)
  local end_line = vim.api.nvim_buf_line_count(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, input_start_line(bufnr, info), end_line, false)
end

local function current_input_text(bufnr, info)
  return table.concat(current_input_lines(bufnr, info), "\n")
end

local function set_current_input(bufnr, info, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end

  local start_line = input_start_line(bufnr, info)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, start_line, -1, false, lines)
  set_input_start(bufnr, info, start_line)
  vim.bo[bufnr].modified = false

  local last_line = start_line + #lines
  local last_col = #lines[#lines]
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_cursor(winid, { last_line, last_col })
  end
  place_prompt(bufnr)
end

local function append_before_input(bufnr, lines)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or #lines == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.bo[bufnr].modifiable = true
  local start_line = input_start_line(bufnr, info)
  vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, lines)
  set_input_start(bufnr, info, start_line + #lines)
  vim.bo[bufnr].modified = false
  place_prompt(bufnr)
end

local function record_submission(info, text)
  info.prompt_state = "busy"
  info.pending_echo_lines = vim.split(text, "\n", { plain = true })
  if info.history[#info.history] ~= text then
    info.history[#info.history + 1] = text
  end
  info.history_index = nil
  info.draft_input = nil
end

local function send_to_job(info, text)
  vim.api.nvim_chan_send(info.jobid, text .. "\n")
  record_submission(info, text)
end

local function parse_output(bufnr, data)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return {}
  end

  local chunk = table.concat(data or {}, "\n")
  chunk = strip_ansi(chunk):gsub("\r", "")
  if chunk == "" then
    return {}
  end

  local text, prompt = strip_prompt_suffix(info.output_pending .. chunk)
  if prompt then
    info.prompt_state = prompt.state
    info.prompt_text = prompt.text
  end

  local complete = {}
  local last_start = 1
  for line, newline in text:gmatch("([^\n]*)(\n?)") do
    if newline == "" then
      break
    end
    complete[#complete + 1] = line
    last_start = last_start + #line + 1
  end

  if text:sub(-1) == "\n" then
    info.output_pending = ""
  else
    info.output_pending = text:sub(last_start)
  end

  if prompt and info.output_pending ~= "" then
    complete[#complete + 1] = info.output_pending
    info.output_pending = ""
  end

  return transcript_lines_from_text(info, table.concat(complete, "\n"))
end

local function on_output(bufnr, _, data, _)
  local lines = parse_output(bufnr, data)
  if #lines == 0 then
    vim.schedule(function()
      place_prompt(bufnr)
    end)
    return
  end

  vim.schedule(function()
    append_before_input(bufnr, lines)
  end)
end

job_running = function(jobid)
  if type(jobid) ~= "number" or jobid <= 0 then
    return false
  end

  return vim.fn.jobwait({ jobid }, 0)[1] == -1
end

local function close_resources(bufnr, opts)
  opts = opts or {}
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return
  end
  if info.resources_closed and opts.forget ~= true then
    return
  end

  if info.status_timer and not info.status_timer:is_closing() then
    info.status_timer:stop()
    info.status_timer:close()
  end
  info.status_timer = nil

  if info.rpc_running ~= false and type(info.rpc_socket) == "string" and info.rpc_socket ~= "" then
    pcall(vim.fn.serverstop, info.rpc_socket)
  end
  info.rpc_running = false

  if opts.stop_job and job_running(info.jobid) then
    pcall(vim.fn.jobstop, info.jobid)
  end

  if opts.closed then
    info.closed = true
  end
  info.resources_closed = true

  publish_status(bufnr)

  if opts.forget then
    state.buffers[bufnr] = nil
  end
end

local function resize_job_to_window(bufnr)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or not job_running(info.jobid) then
    return
  end

  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local width = vim.api.nvim_win_get_width(winid)
  local height = vim.api.nvim_win_get_height(winid)
  pcall(vim.fn.jobresize, info.jobid, width, height)
end

local function console_info(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "not an Ark console buffer"
  end
  return info, nil, bufnr
end

local function start_job(bufnr, opts, session_id, status_path)
  local runtime = opts.terminal or opts.tmux or {}
  local launcher = runtime.launcher
  if type(launcher) ~= "string" or launcher == "" then
    return nil, "ark.nvim console requires a launcher"
  end

  local jobid = vim.fn.jobstart({ launcher }, {
    cwd = vim.fn.getcwd(),
    env = shell_env(runtime, session_id, status_path),
    pty = true,
    on_stdout = function(...)
      on_output(bufnr, ...)
    end,
    on_stderr = function(...)
      on_output(bufnr, ...)
    end,
    on_exit = function(_, code, _)
      vim.schedule(function()
        local info = state.buffers[bufnr]
        if type(info) == "table" then
          info.exit_code = code
          close_resources(bufnr, { closed = true })
        end
        append_before_input(bufnr, { "#> [ark console exited: " .. tostring(code) .. "]" })
      end)
    end,
  })

  if type(jobid) ~= "number" or jobid <= 0 then
    return nil, "failed to start Ark console launcher"
  end

  vim.schedule(function()
    resize_job_to_window(bufnr)
  end)

  return jobid, nil
end

local function create_buffer()
  vim.cmd("botright split")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.b[bufnr].ark_console = true
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = true
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "r"
  vim.api.nvim_buf_set_name(bufnr, "ark-console://" .. tostring(vim.fn.getpid()) .. "/" .. tostring(bufnr) .. "/input.R")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  return bufnr
end

local function console_buffer()
  for bufnr, info in pairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and job_running(info.jobid) then
      return bufnr, info
    end
  end
  return nil, nil
end

function M.start(opts)
  opts = opts or {}
  local existing = console_buffer()
  if existing then
    local winid = vim.fn.bufwinid(existing)
    if type(winid) == "number" and winid > 0 then
      vim.api.nvim_set_current_win(winid)
    else
      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, existing)
    end
    return existing
  end

  local bufnr = create_buffer()
  local session_id = session_id_for_buffer(bufnr)
  local runtime = opts.terminal or opts.tmux or {}
  local socket_path = rpc_socket_path(runtime, session_id)
  local socket_dir = vim.fs.dirname(socket_path)
  if type(socket_dir) == "string" and socket_dir ~= "" then
    vim.fn.mkdir(socket_dir, "p")
  end
  state.buffers[bufnr] = {
    draft_input = nil,
    history = {},
    history_index = nil,
    input_mark_id = nil,
    input_start = 0,
    jobid = nil,
    output_pending = "",
    pending_echo_lines = {},
    prompt_state = "top-level",
    rpc_socket = socket_path,
    rpc_running = false,
    session_id = session_id,
    status_path = session_runtime.status_file_path(runtime, session_id),
    status_timer = nil,
  }
  set_input_start(bufnr, state.buffers[bufnr], 0)
  place_prompt(bufnr)

  local ok_server, server_result = pcall(vim.fn.serverstart, state.buffers[bufnr].rpc_socket)
  if ok_server and type(server_result) == "string" and server_result ~= "" then
    state.buffers[bufnr].rpc_socket = server_result
    state.buffers[bufnr].rpc_running = true
  else
    state.buffers[bufnr].rpc_running = false
    append_before_input(bufnr, { "#> failed to start Ark console RPC server: " .. tostring(server_result) })
  end
  state.buffers[bufnr].status_timer = start_status_publisher(bufnr)

  if opts.auto_start_lsp ~= false then
    lsp.start(opts, bufnr, {
      wait_for_client = false,
    })
  end

  local jobid, err = start_job(bufnr, opts, session_id, state.buffers[bufnr].status_path)
  if not jobid then
    append_before_input(bufnr, { "#> " .. tostring(err) })
    return nil, err
  end
  state.buffers[bufnr].jobid = jobid

  _G[console_server_fn] = function(text)
    local ok, send_err = M.send_text(bufnr, text)
    if not ok then
      error(send_err or "failed to send text to Ark console", 0)
    end
    return "ok"
  end

  vim.keymap.set({ "n", "i" }, "<CR>", function()
    M.submit_or_accept_completion(bufnr)
  end, { buffer = bufnr, desc = "Submit Ark console input" })
  vim.keymap.set({ "n", "i" }, "<M-CR>", function()
    M.insert_newline(bufnr)
  end, { buffer = bufnr, desc = "Insert newline in Ark console input" })
  vim.keymap.set({ "n", "i" }, "<C-p>", function()
    M.history_prev(bufnr)
  end, { buffer = bufnr, desc = "Previous Ark console input" })
  vim.keymap.set({ "n", "i" }, "<C-n>", function()
    M.history_next(bufnr)
  end, { buffer = bufnr, desc = "Next Ark console input" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    M.interrupt(bufnr)
  end, { buffer = bufnr, desc = "Interrupt Ark console R process" })
  vim.keymap.set({ "n", "i" }, "<C-d>", function()
    M.eof(bufnr)
  end, { buffer = bufnr, desc = "Send EOF to Ark console R process" })

  vim.api.nvim_create_autocmd("WinResized", {
    group = vim.api.nvim_create_augroup("ArkConsoleResize" .. tostring(bufnr), { clear = true }),
    callback = function()
      resize_job_to_window(bufnr)
    end,
    desc = "Resize Ark console PTY when its window changes",
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("ArkConsoleLifecycle" .. tostring(bufnr), { clear = true }),
    callback = function()
      close_resources(bufnr, {
        closed = true,
        forget = true,
        stop_job = true,
      })
    end,
    desc = "Stop Ark console resources when its buffer is wiped",
  })

  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function()
      vim.schedule(function()
        close_resources(bufnr, {
          closed = true,
          forget = true,
          stop_job = true,
        })
      end)
    end,
  })

  vim.cmd("startinsert")
  return bufnr
end

function M.submit_or_accept_completion(bufnr)
  local ok, cmp = pcall(require, "blink.cmp")
  if ok and type(cmp) == "table" and type(cmp.accept) == "function" and type(cmp.is_visible) == "function" then
    local visible_ok, visible = pcall(cmp.is_visible)
    if visible_ok and visible then
      local accepted_ok, accepted = pcall(cmp.accept)
      if accepted_ok and accepted then
        return true
      end
      if type(cmp.select_and_accept) == "function" then
        accepted_ok, accepted = pcall(cmp.select_and_accept)
        if accepted_ok and accepted then
          return true
        end
      end
      return true
    end
  end

  return M.submit(bufnr)
end

function M.submit(bufnr)
  local info, err, resolved_bufnr = console_info(bufnr)
  if not info then
    return nil, err
  end
  bufnr = resolved_bufnr
  if not job_running(info.jobid) then
    return nil, "Ark console R process is not running"
  end

  local end_line = vim.api.nvim_buf_line_count(bufnr)
  local lines = current_input_lines(bufnr, info)
  local text = table.concat(lines, "\n")
  if text:gsub("%s+", "") == "" then
    return true
  end

  send_to_job(info, text)

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, end_line, end_line, false, { "" })
  set_input_start(bufnr, info, end_line)
  vim.api.nvim_win_set_cursor(0, { input_start_line(bufnr, info) + 1, 0 })
  vim.bo[bufnr].modified = false
  place_prompt(bufnr)
  return true
end

function M.insert_newline(bufnr)
  local info, err, resolved_bufnr = console_info(bufnr)
  if not info then
    return nil, err
  end
  bufnr = resolved_bufnr

  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return nil, "Ark console buffer is not visible"
  end

  local input_start = input_start_line(bufnr, info)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row = math.max(cursor[1] - 1, input_start)
  if row ~= cursor[1] - 1 then
    vim.api.nvim_win_set_cursor(winid, { row + 1, 0 })
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local col = math.max(0, math.min(cursor[2], #line))
  local before = line:sub(1, col)
  local after = line:sub(col + 1)

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before, after })
  vim.bo[bufnr].modified = false
  vim.api.nvim_win_set_cursor(winid, { row + 2, 0 })
  place_prompt(bufnr)
  return true
end

function M.send_text(bufnr, text)
  local info, err, resolved_bufnr = console_info(bufnr)
  if not info then
    return nil, err
  end
  bufnr = resolved_bufnr
  if not job_running(info.jobid) then
    return nil, "Ark console R process is not running"
  end
  if type(text) ~= "string" or text == "" then
    return nil, "Ark console send_text() requires non-empty text"
  end

  text = text:gsub("\n+$", "")
  if text == "" then
    return true
  end

  info.last_send = text
  info.last_send_ms = math.floor(vim.loop.hrtime() / 1e6)
  publish_status(bufnr)
  append_before_input(bufnr, vim.split(text, "\n", { plain = true }))
  send_to_job(info, text)
  place_prompt(bufnr)
  return true
end

function M.history_prev(bufnr)
  local info, err, resolved_bufnr = console_info(bufnr)
  if not info then
    return nil, err
  end
  bufnr = resolved_bufnr
  if #info.history == 0 then
    return true
  end

  if info.history_index == nil then
    info.draft_input = current_input_text(bufnr, info)
    info.history_index = #info.history
  elseif info.history_index > 1 then
    info.history_index = info.history_index - 1
  end

  set_current_input(bufnr, info, info.history[info.history_index] or "")
  return true
end

function M.history_next(bufnr)
  local info, err, resolved_bufnr = console_info(bufnr)
  if not info then
    return nil, err
  end
  bufnr = resolved_bufnr
  if info.history_index == nil then
    return true
  end

  if info.history_index < #info.history then
    info.history_index = info.history_index + 1
    set_current_input(bufnr, info, info.history[info.history_index] or "")
  else
    info.history_index = nil
    set_current_input(bufnr, info, info.draft_input or "")
    info.draft_input = nil
  end

  return true
end

function M.interrupt(bufnr)
  local info, err = console_info(bufnr)
  if not info then
    return nil, err
  end
  if not job_running(info.jobid) then
    return nil, "Ark console R process is not running"
  end

  vim.api.nvim_chan_send(info.jobid, "\003")
  return true
end

function M.eof(bufnr)
  local info, err = console_info(bufnr)
  if not info then
    return nil, err
  end
  if not job_running(info.jobid) then
    return nil, "Ark console R process is not running"
  end

  vim.api.nvim_chan_send(info.jobid, "\004")
  return true
end

function M.stop(bufnr)
  local info, err = console_info(bufnr)
  if not info then
    return nil, err
  end
  if not job_running(info.jobid) then
    close_resources(bufnr, { closed = true })
    return true
  end

  pcall(vim.fn.jobstop, info.jobid)
  return true
end

function M.status(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return nil
  end
  return vim.deepcopy({
    bufnr = bufnr,
    history = info.history,
    history_index = info.history_index,
    input_start = input_start_line(bufnr, info),
    jobid = info.jobid,
    exit_code = info.exit_code,
    prompt_state = info.prompt_state,
    rpc_socket = info.rpc_socket,
    running = job_running(info.jobid),
    session_id = info.session_id,
    status_path = info.status_path,
  })
end

return M
