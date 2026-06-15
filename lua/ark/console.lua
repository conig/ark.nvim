local lsp = require("ark.lsp")
local session_runtime = require("ark.session_runtime")

local M = {}

local prompt_ns = vim.api.nvim_create_namespace("ArkConsole")
local transcript_prompt_ns = vim.api.nvim_create_namespace("ArkConsoleTranscriptPrompt")
local input_ns = vim.api.nvim_create_namespace("ArkConsoleInput")
local ansi_ns = vim.api.nvim_create_namespace("ArkConsoleAnsi")
local console_server_fn = "__ark_console_rpc_send"
local job_running
local install_paste_handler
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

  local command = { "tmux" }
  local explicit_socket = vim.env.ARK_TMUX_SOCKET
  if type(explicit_socket) == "string" and explicit_socket ~= "" then
    vim.list_extend(command, { "-S", explicit_socket })
  else
    local socket = vim.split(vim.env.TMUX, ",", { plain = true })[1]
    if type(socket) == "string" and socket ~= "" then
      vim.list_extend(command, { "-S", socket })
    end
  end

  vim.list_extend(command, { "display-message", "-p" })
  if type(vim.env.TMUX_PANE) == "string" and vim.env.TMUX_PANE ~= "" then
    vim.list_extend(command, { "-t", vim.env.TMUX_PANE })
  end
  command[#command + 1] = "#{socket_path}\n#{session_name}\n#{pane_id}"

  local output = vim.fn.systemlist(command)
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

local function shell_env(config, session_id, status_path, backend)
  local env = {
    ARK_STATUS_DIR = config.startup_status_dir,
    ARK_NVIM_SESSION_PKG_PATH = config.session_pkg_path,
    ARK_SESSION_KIND = config.session_kind or "ark",
    ARK_SESSION_BACKEND = backend or "nvim-console",
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

  local payload = {}
  if vim.fn.filereadable(path) == 1 then
    local ok, decoded = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    if ok and type(decoded) == "table" then
      payload = decoded
    end
  end

  local before = vim.deepcopy(payload)
  for key, value in pairs(patch) do
    payload[key] = value
  end

  if vim.deep_equal(payload, before) then
    return
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

local ansi_palette = {
  [0] = "#2e3436",
  [1] = "#cc0000",
  [2] = "#4e9a06",
  [3] = "#c4a000",
  [4] = "#3465a4",
  [5] = "#75507b",
  [6] = "#06989a",
  [7] = "#d3d7cf",
  [8] = "#555753",
  [9] = "#ef2929",
  [10] = "#8ae234",
  [11] = "#fce94f",
  [12] = "#729fcf",
  [13] = "#ad7fa8",
  [14] = "#34e2e2",
  [15] = "#eeeeec",
}

local ansi_hl_cache = {}
local ansi_hl_count = 0

local function color_hex(red, green, blue)
  red = math.max(0, math.min(255, tonumber(red) or 0))
  green = math.max(0, math.min(255, tonumber(green) or 0))
  blue = math.max(0, math.min(255, tonumber(blue) or 0))
  return string.format("#%02x%02x%02x", red, green, blue)
end

local function xterm_256_color(index)
  index = tonumber(index)
  if not index or index < 0 or index > 255 then
    return nil
  end
  if ansi_palette[index] then
    return ansi_palette[index]
  end
  if index >= 16 and index <= 231 then
    local value = index - 16
    local levels = { 0, 95, 135, 175, 215, 255 }
    local red = levels[math.floor(value / 36) + 1]
    local green = levels[math.floor((value % 36) / 6) + 1]
    local blue = levels[(value % 6) + 1]
    return color_hex(red, green, blue)
  end

  local gray = 8 + ((index - 232) * 10)
  return color_hex(gray, gray, gray)
end

local function reset_ansi_style(style)
  for key, _ in pairs(style) do
    style[key] = nil
  end
end

local function parse_sgr_params(raw)
  if type(raw) ~= "string" or raw == "" then
    return { 0 }
  end

  local params = {}
  for part in raw:gmatch("[^;:]+") do
    params[#params + 1] = tonumber(part) or 0
  end

  if #params == 0 then
    return { 0 }
  end

  return params
end

local function apply_sgr(style, raw)
  local params = parse_sgr_params(raw)
  local index = 1

  while index <= #params do
    local code = params[index]

    if code == 0 then
      reset_ansi_style(style)
    elseif code == 1 then
      style.bold = true
    elseif code == 3 then
      style.italic = true
    elseif code == 4 then
      style.underline = true
    elseif code == 7 then
      style.reverse = true
    elseif code == 22 then
      style.bold = nil
    elseif code == 23 then
      style.italic = nil
    elseif code == 24 then
      style.underline = nil
    elseif code == 27 then
      style.reverse = nil
    elseif code == 39 then
      style.fg = nil
    elseif code >= 30 and code <= 37 then
      style.fg = ansi_palette[code - 30]
    elseif code >= 90 and code <= 97 then
      style.fg = ansi_palette[(code - 90) + 8]
    elseif code == 38 then
      local mode = params[index + 1]
      if mode == 5 then
        style.fg = xterm_256_color(params[index + 2])
        index = index + 2
      elseif mode == 2 then
        style.fg = color_hex(params[index + 2], params[index + 3], params[index + 4])
        index = index + 4
      end
    end

    index = index + 1
  end
end

local function ansi_style_group(style)
  if type(style) ~= "table" then
    return nil
  end
  if not style.fg and not style.bold and not style.italic and not style.underline and not style.reverse then
    return nil
  end

  local key = table.concat({
    style.fg or "",
    style.bold and "1" or "0",
    style.italic and "1" or "0",
    style.underline and "1" or "0",
    style.reverse and "1" or "0",
  }, ":")
  if ansi_hl_cache[key] then
    return ansi_hl_cache[key]
  end

  ansi_hl_count = ansi_hl_count + 1
  local group = "ArkConsoleAnsi" .. tostring(ansi_hl_count)
  local opts = {
    bold = style.bold == true,
    italic = style.italic == true,
    underline = style.underline == true,
    reverse = style.reverse == true,
  }
  if type(style.fg) == "string" and style.fg ~= "" then
    opts.fg = style.fg
  end
  pcall(vim.api.nvim_set_hl, 0, group, opts)
  ansi_hl_cache[key] = group
  return group
end

local function truncate_spans(spans, max_col)
  local out = {}
  max_col = tonumber(max_col) or 0
  for _, span in ipairs(spans or {}) do
    local start_col = tonumber(span.start_col) or 0
    local end_col = math.min(tonumber(span.end_col) or 0, max_col)
    if end_col > start_col then
      out[#out + 1] = {
        start_col = start_col,
        end_col = end_col,
        hl_group = span.hl_group,
      }
    end
  end
  return out
end

local function offset_spans(spans, offset)
  local out = {}
  offset = tonumber(offset) or 0
  for _, span in ipairs(spans or {}) do
    out[#out + 1] = {
      start_col = (tonumber(span.start_col) or 0) + offset,
      end_col = (tonumber(span.end_col) or 0) + offset,
      hl_group = span.hl_group,
    }
  end
  return out
end

local function strip_span_prefix(spans, prefix_len)
  local out = {}
  prefix_len = tonumber(prefix_len) or 0
  for _, span in ipairs(spans or {}) do
    local start_col = (tonumber(span.start_col) or 0) - prefix_len
    local end_col = (tonumber(span.end_col) or 0) - prefix_len
    if end_col > 0 then
      out[#out + 1] = {
        start_col = math.max(0, start_col),
        end_col = end_col,
        hl_group = span.hl_group,
      }
    end
  end
  return out
end

local function set_span_range(spans, start_col, end_col, hl_group)
  local out = {}

  for _, span in ipairs(spans or {}) do
    local span_start = tonumber(span.start_col) or 0
    local span_end = tonumber(span.end_col) or 0
    if span_end <= start_col or span_start >= end_col then
      out[#out + 1] = span
    else
      if span_start < start_col then
        out[#out + 1] = {
          start_col = span_start,
          end_col = start_col,
          hl_group = span.hl_group,
        }
      end
      if span_end > end_col then
        out[#out + 1] = {
          start_col = end_col,
          end_col = span_end,
          hl_group = span.hl_group,
        }
      end
    end
  end

  if type(hl_group) == "string" and hl_group ~= "" then
    out[#out + 1] = {
      start_col = start_col,
      end_col = end_col,
      hl_group = hl_group,
    }
  end

  table.sort(out, function(lhs, rhs)
    if lhs.start_col == rhs.start_col then
      return lhs.end_col < rhs.end_col
    end
    return lhs.start_col < rhs.start_col
  end)

  local merged = {}
  for _, span in ipairs(out) do
    local last = merged[#merged]
    if last and last.hl_group == span.hl_group and last.end_col == span.start_col then
      last.end_col = span.end_col
    elseif span.end_col > span.start_col then
      merged[#merged + 1] = span
    end
  end

  return merged
end

local function line_text(item)
  if type(item) == "table" then
    return item.text or ""
  end
  return tostring(item or "")
end

local function line_spans(item)
  if type(item) == "table" and type(item.spans) == "table" then
    return item.spans
  end
  return {}
end

local function split_plain_lines(text)
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = {
      text = line,
      spans = {},
    }
  end
  return lines
end

local function consume_terminal_output(info, chunk)
  chunk = (info.output_escape_pending or "") .. (chunk or "")
  info.output_escape_pending = nil

  local complete = {}
  local current = info.output_pending or ""
  local spans = info.output_pending_spans or {}
  local cursor = tonumber(info.output_cursor) or #current
  local style = info.output_style or {}
  local line_returned = info.output_line_returned == true
  local overwrite_end = tonumber(info.output_overwrite_end)
  local index = 1

  local function clear_line()
    current = ""
    spans = {}
    cursor = 0
    line_returned = false
    overwrite_end = nil
  end

  local function clip_current_to_overwrite(force)
    if not line_returned then
      return
    end
    if not force and (overwrite_end or 0) == 0 then
      return
    end

    local max_col = math.max(0, math.min(overwrite_end or 0, #current))
    current = current:sub(1, max_col)
    spans = truncate_spans(spans, max_col)
    cursor = math.min(cursor, #current)
    line_returned = false
    overwrite_end = nil
  end

  local function append_text(text)
    if text == "" then
      return
    end

    local start_col = cursor
    local text_len = #text
    if cursor < #current then
      current = current:sub(1, cursor) .. text .. current:sub(cursor + text_len + 1)
    elseif cursor == #current then
      current = current .. text
    else
      current = current .. string.rep(" ", cursor - #current) .. text
    end

    local hl_group = ansi_style_group(style)
    cursor = cursor + text_len
    spans = set_span_range(spans, start_col, cursor, hl_group)
    if line_returned then
      overwrite_end = math.max(overwrite_end or 0, cursor)
    end
  end

  local function csi_final_offset(start)
    local cursor = start
    while cursor <= #chunk do
      local byte = chunk:byte(cursor)
      if byte and byte >= 0x40 and byte <= 0x7e then
        return cursor
      end
      cursor = cursor + 1
    end
    return nil
  end

  local function osc_final_offset(start)
    local cursor = start
    while cursor <= #chunk do
      local byte = chunk:byte(cursor)
      if byte == 0x07 then
        return cursor
      end
      if byte == 0x1b and chunk:sub(cursor + 1, cursor + 1) == "\\" then
        return cursor + 1
      end
      cursor = cursor + 1
    end
    return nil
  end

  while index <= #chunk do
    local char = chunk:sub(index, index)
    if char == "\27" then
      local introducer = chunk:sub(index + 1, index + 1)
      if introducer == "[" then
        local final = csi_final_offset(index + 2)
        if not final then
          info.output_escape_pending = chunk:sub(index)
          break
        end

        local final_char = chunk:sub(final, final)
        local params = chunk:sub(index + 2, final - 1)
        if final_char == "m" then
          apply_sgr(style, params)
        elseif final_char == "K" then
          clear_line()
        end
        index = final
      elseif introducer == "]" then
        local final = osc_final_offset(index + 2)
        if not final then
          info.output_escape_pending = chunk:sub(index)
          break
        end
        index = final
      elseif introducer ~= "" then
        index = index + 1
      end
    elseif char == "\r" then
      local next_char = chunk:sub(index + 1, index + 1)
      if next_char ~= "\n" then
        clip_current_to_overwrite(false)
        cursor = 0
        line_returned = true
        overwrite_end = 0
      end
    elseif char == "\n" then
      clip_current_to_overwrite(true)
      complete[#complete + 1] = {
        text = current,
        spans = spans,
      }
      clear_line()
    else
      local next_control = chunk:find("[\r\n\27]", index)
      local text_end = next_control and (next_control - 1) or #chunk
      append_text(chunk:sub(index, text_end))
      index = text_end
    end
    index = index + 1
  end

  clip_current_to_overwrite(false)
  info.output_pending = current
  info.output_pending_spans = spans
  info.output_cursor = cursor
  info.output_style = style
  info.output_line_returned = line_returned
  info.output_overwrite_end = overwrite_end
  return complete
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

local function prompt_prefix_stripped(line)
  local patterns = {
    "^%s*Browse%[[0-9]+%]>%s*",
    "^%s*debug>%s*",
    "^%s*recover>%s*",
    "^%s*>%s+",
  }

  for _, pattern in ipairs(patterns) do
    local stripped, count = line:gsub(pattern, "", 1)
    if count > 0 then
      return stripped, #line - #stripped
    end
  end

  return nil
end

local function prompt_only_line(line)
  return line:match("^%s*Browse%[[0-9]+%]>%s*$") ~= nil
    or line:match("^%s*debug>%s*$") ~= nil
    or line:match("^%s*recover>%s*$") ~= nil
    or line:match("^%s*>%s*$") ~= nil
    or line:match("^%s*%+%s*$") ~= nil
end

local function styled_chunks(text, spans, default_hl)
  text = text or ""
  spans = spans or {}
  local chunks = {}
  local cursor = 0

  for _, span in ipairs(spans) do
    local start_col = math.max(cursor, tonumber(span.start_col) or 0)
    local end_col = math.min(#text, tonumber(span.end_col) or 0)
    if start_col > cursor then
      chunks[#chunks + 1] = { text:sub(cursor + 1, start_col), default_hl }
    end
    if end_col > start_col then
      chunks[#chunks + 1] = { text:sub(start_col + 1, end_col), span.hl_group or default_hl }
      cursor = end_col
    end
  end

  if cursor < #text then
    chunks[#chunks + 1] = { text:sub(cursor + 1), default_hl }
  end

  if #chunks == 0 then
    chunks[#chunks + 1] = { text, default_hl }
  end

  return chunks
end

local function transcript_lines_from_output(info, output)
  if type(output) == "string" then
    output = split_plain_lines(output)
  end

  local lines = {}
  for _, item in ipairs(output or {}) do
    local line = line_text(item)
    local stripped, prefix_len = prompt_prefix_stripped(line)
    local plus_stripped = line:gsub("^%s*%+%s+", "", 1)
    local display_line = stripped or line
    local display_spans = stripped and strip_span_prefix(line_spans(item), prefix_len) or line_spans(item)
    local trimmed = display_line:gsub("^%s+", ""):gsub("%s+$", "")
    local is_echo = pop_echo_line(info, line)
      or (stripped ~= nil and pop_echo_line(info, stripped))
      or (plus_stripped ~= line and pop_echo_line(info, plus_stripped))
    if trimmed ~= "" and not prompt_only_line(line) and not is_echo then
      lines[#lines + 1] = {
        text = "#> " .. display_line,
        spans = offset_spans(display_spans, 3),
      }
    end
  end
  return lines
end

local function pending_output_chunks(info)
  if type(info) ~= "table" then
    return nil
  end
  local pending = info.output_pending
  if type(pending) ~= "string" or pending == "" then
    return nil
  end
  if info.prompt_state ~= "busy" and (type(job_running) ~= "function" or not job_running(info.jobid)) then
    return nil
  end

  return styled_chunks(pending, info.output_pending_spans or {}, "ArkConsoleOutput")
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
local place_prompt
local focus_input
local paste_text_at_input_cursor

local function setup_highlights()
  pcall(vim.api.nvim_set_hl, 0, "ArkConsolePrompt", { link = "Question", default = true })
  pcall(vim.api.nvim_set_hl, 0, "ArkConsoleOutput", { link = "Normal", default = true })
  pcall(vim.api.nvim_set_hl, 0, "ArkConsoleOutputPrefix", { link = "Comment", default = true })
end

local function place_prompt_extmark(bufnr, ns, line, label, group)
  vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
    virt_text = { { label, group or "ArkConsolePrompt" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

local function place_prompt_chunks_extmark(bufnr, ns, line, chunks)
  vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
    virt_text = chunks,
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

local function snapshot_transcript_prompts(bufnr)
  local prompts = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, transcript_prompt_ns, 0, -1, { details = true })) do
    local details = mark[4]
    local virt_text = type(details) == "table" and details.virt_text or nil
    local chunk = type(virt_text) == "table" and virt_text[1] or nil
    local label = type(chunk) == "table" and chunk[1] or nil
    if type(label) == "string" then
      prompts[#prompts + 1] = {
        line = mark[2],
        label = label,
      }
    end
  end
  return prompts
end

local function restore_transcript_prompts(bufnr, prompts)
  vim.api.nvim_buf_clear_namespace(bufnr, transcript_prompt_ns, 0, -1)
  if type(prompts) ~= "table" then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, prompt in ipairs(prompts) do
    local line = tonumber(prompt.line)
    if line and line >= 0 and line < line_count and type(prompt.label) == "string" then
      place_prompt_extmark(bufnr, transcript_prompt_ns, line, prompt.label)
    end
  end
end

local function place_transcript_prompts(bufnr, start_line, line_count, first_prompt)
  line_count = tonumber(line_count) or 0
  if line_count <= 0 then
    return
  end

  for offset = 0, line_count - 1 do
    local label = offset == 0 and first_prompt or "+ "
    place_prompt_extmark(bufnr, transcript_prompt_ns, start_line + offset, label)
  end
end

place_prompt = function(bufnr)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, prompt_ns, 0, -1)
  local line = input_start_line(bufnr, info)
  local pending_chunks = pending_output_chunks(info)
  if pending_chunks then
    place_prompt_chunks_extmark(bufnr, prompt_ns, line, pending_chunks)
  else
    place_prompt_extmark(bufnr, prompt_ns, line, prompt_label(info))
  end
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

local function refresh_valid_snapshot(bufnr, info)
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  info.valid_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  info.valid_input_start = tonumber(info.input_start) or input_start_line(bufnr, info)
  info.valid_transcript_prompts = snapshot_transcript_prompts(bufnr)
end

local function restore_valid_snapshot(bufnr, info)
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  info.protected_edit_reject_pending = false
  info.reverting_protected_edit = true

  local lines = type(info.valid_lines) == "table" and vim.deepcopy(info.valid_lines) or { "" }
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_input_start(bufnr, info, tonumber(info.valid_input_start) or vim.api.nvim_buf_line_count(bufnr) - 1)
  restore_transcript_prompts(bufnr, info.valid_transcript_prompts)
  info.reverting_protected_edit = false

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.bo[bufnr].modified = false
    refresh_valid_snapshot(bufnr, info)
    place_prompt(bufnr)
    if type(focus_input) == "function" then
      local mode = vim.api.nvim_get_mode().mode
      focus_input(bufnr, info, {
        insert = type(mode) == "string" and mode:sub(1, 1) == "i",
      })
    end
  end

  return true
end

local function restore_pending_protected_edit(bufnr, info)
  if type(info) == "table" and info.protected_edit_reject_pending == true then
    restore_valid_snapshot(bufnr, info)
  end
end

local function with_internal_edit(bufnr, info, callback)
  restore_pending_protected_edit(bufnr, info)
  info.internal_edit = (tonumber(info.internal_edit) or 0) + 1
  local results = { pcall(callback) }
  info.internal_edit = math.max(0, (tonumber(info.internal_edit) or 1) - 1)
  if not results[1] then
    error(results[2], 0)
  end

  refresh_valid_snapshot(bufnr, info)
  return unpack(results, 2)
end

local function current_input_lines(bufnr, info)
  local end_line = vim.api.nvim_buf_line_count(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, input_start_line(bufnr, info), end_line, false)
end

local function current_input_text(bufnr, info)
  return table.concat(current_input_lines(bufnr, info), "\n")
end

focus_input = function(bufnr, info, opts)
  opts = opts or {}
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  if vim.api.nvim_get_current_win() ~= winid then
    pcall(vim.api.nvim_set_current_win, winid)
  end

  local start_line = input_start_line(bufnr, info)
  local input_lines = current_input_lines(bufnr, info)
  if #input_lines == 0 then
    input_lines = { "" }
  end

  local target_row = start_line + #input_lines
  local target_col = #input_lines[#input_lines]
  if opts.position == "start" then
    target_row = start_line + 1
    target_col = 0
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  target_row = math.max(1, math.min(target_row, line_count))
  local target_line = vim.api.nvim_buf_get_lines(bufnr, target_row - 1, target_row, false)[1] or ""
  target_col = math.max(0, math.min(target_col, #target_line))
  pcall(vim.api.nvim_win_set_cursor, winid, { target_row, target_col })

  if opts.insert == true then
    local function enter_insert_mode()
      if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_win_is_valid(winid) then
        return
      end
      if vim.api.nvim_get_current_win() ~= winid then
        pcall(vim.api.nvim_set_current_win, winid)
      end
      pcall(vim.cmd, "startinsert")
    end

    enter_insert_mode()
    vim.schedule(enter_insert_mode)
  end

  return true
end

local function set_current_input(bufnr, info, text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end

  local start_line = input_start_line(bufnr, info)
  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, start_line, -1, false, lines)
    set_input_start(bufnr, info, start_line)
    vim.bo[bufnr].modified = false
  end)

  local last_line = start_line + #lines
  local last_col = #lines[#lines]
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_cursor(winid, { last_line, last_col })
  end
  place_prompt(bufnr)
end

local function hide_blink_completion()
  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  if ok_trigger and type(trigger.hide) == "function" then
    pcall(trigger.hide)
  end

  local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
  if ok_menu and type(menu) == "table" and type(menu.close) == "function" then
    pcall(menu.close)
  end
end

local function blink_completion_visible_for_signature_help()
  local ok, cmp = pcall(require, "blink.cmp")
  if not ok or type(cmp) ~= "table" then
    return false
  end

  if type(cmp.is_menu_visible) == "function" then
    local visible_ok, visible = pcall(cmp.is_menu_visible)
    if visible_ok and visible == true then
      return true
    end
  end

  if type(cmp.is_visible) == "function" then
    local visible_ok, visible = pcall(cmp.is_visible)
    return visible_ok and visible == true
  end

  return false
end

local function close_lsp_info_floats()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local config = vim.api.nvim_win_get_config(winid)
    if type(config) == "table" and type(config.relative) == "string" and config.relative ~= "" then
      local has_lsp_float_var = false
      for _, var in ipairs({ "textDocument/signatureHelp", "textDocument/hover", "lsp_floating_bufnr" }) do
        local ok = pcall(vim.api.nvim_win_get_var, winid, var)
        if ok then
          has_lsp_float_var = true
          break
        end
      end

      if has_lsp_float_var then
        pcall(vim.api.nvim_win_close, winid, true)
      end
    end
  end
end

local function suppress_lsp_info_for_blink_completion()
  if not blink_completion_visible_for_signature_help() then
    return false
  end

  close_lsp_info_floats()
  return true
end

local signature_help_trigger_chars = {
  ["("] = true,
  [","] = true,
  ["="] = true,
}

local function cursor_in_input(bufnr, info)
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row = tonumber(cursor[1])
  if not row or (row - 1) < input_start_line(bufnr, info) then
    return nil
  end

  return cursor
end

local function signature_help_trigger_before_cursor(bufnr, info)
  local cursor = cursor_in_input(bufnr, info)
  if not cursor then
    return nil
  end

  local col = tonumber(cursor[2])
  if not col or col <= 0 then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local char = line:sub(col, col)
  if signature_help_trigger_chars[char] then
    return char
  end

  return nil
end

local function has_signature_help_client(bufnr)
  local ok, clients = pcall(vim.lsp.get_clients, {
    bufnr = bufnr,
    name = "ark_lsp",
    method = "textDocument/signatureHelp",
  })
  if ok and type(clients) == "table" then
    return clients[1] ~= nil
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" }) or {}) do
    local provider = client.server_capabilities and client.server_capabilities.signatureHelpProvider
    if provider then
      return true
    end
  end

  return false
end

local function maybe_show_signature_help(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end

  local info = state.buffers[bufnr]
  if type(info) ~= "table" or vim.b[bufnr].ark_console ~= true then
    return
  end

  if suppress_lsp_info_for_blink_completion() then
    return
  end

  local trigger = signature_help_trigger_before_cursor(bufnr, info)
  if not trigger or not has_signature_help_client(bufnr) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local key = table.concat({ cursor[1], cursor[2], trigger }, ":")
  if info.last_signature_help_trigger == key then
    return
  end
  info.last_signature_help_trigger = key

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    if not signature_help_trigger_before_cursor(bufnr, info) then
      return
    end
    if suppress_lsp_info_for_blink_completion() then
      return
    end
    pcall(vim.lsp.buf.signature_help, {
      focusable = false,
      silent = true,
    })
  end)
end

local function paste_lines_text(lines)
  if type(lines) == "table" then
    return table.concat(lines, "\n")
  end
  if type(lines) == "string" then
    return lines
  end
  return ""
end

local function console_paste_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or vim.b[bufnr].ark_console ~= true then
    return nil, nil
  end
  return bufnr, info
end

install_paste_handler = function()
  if state.console_paste_handler_installed == true then
    return
  end

  local base_paste = vim.paste
  state.console_base_paste = state.console_base_paste or base_paste
  state.console_paste_handler_installed = true

  vim.paste = function(lines, phase)
    local bufnr, info = console_paste_buffer()
    if not bufnr then
      return state.console_base_paste(lines, phase)
    end

    local text = paste_lines_text(lines)
    if phase == 1 then
      info.pending_paste_text = text
      return true
    elseif phase == 2 then
      info.pending_paste_text = (info.pending_paste_text or "") .. text
      return true
    elseif phase == 3 then
      text = (info.pending_paste_text or "") .. text
      info.pending_paste_text = nil
    end

    if phase == -1 then
      info.pending_paste_text = nil
    end

    hide_blink_completion()
    local ok, err = paste_text_at_input_cursor(bufnr, info, text)
    if not ok then
      vim.notify(err or "failed to paste into Ark console", vim.log.levels.ERROR)
    end
    return true
  end
end

local function cursor_before_input(bufnr, info)
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  return type(cursor) == "table" and tonumber(cursor[1]) ~= nil and (cursor[1] - 1) < input_start_line(bufnr, info)
end

local function cursor_on_or_after_input(bufnr, info)
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  return type(cursor) == "table" and tonumber(cursor[1]) ~= nil and (cursor[1] - 1) >= input_start_line(bufnr, info)
end

local function cursor_on_input_line(bufnr, info)
  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(winid)
  return type(cursor) == "table" and tonumber(cursor[1]) ~= nil and (cursor[1] - 1) == input_start_line(bufnr, info)
end

local function enter_insert_from_normal_i(bufnr)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    vim.api.nvim_feedkeys(vim.keycode("i"), "n", false)
    return
  end

  if cursor_on_input_line(bufnr, info) then
    pcall(vim.cmd, "startinsert")
    return
  end

  focus_input(bufnr, info, { insert = true, position = "start" })
end

local function focus_input_for_normal_edit(bufnr)
  local info = state.buffers[bufnr]
  if type(info) == "table" then
    focus_input(bufnr, info, { insert = true })
    return
  end

  vim.api.nvim_feedkeys(vim.keycode("i"), "n", false)
end

local function open_input_line_for_normal_edit(bufnr, opts)
  opts = opts or {}
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    local key = opts.above == true and "O" or "o"
    vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
    return false
  end

  if not cursor_on_or_after_input(bufnr, info) then
    focus_input(bufnr, info, { insert = true })
    return true
  end

  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local start_line = input_start_line(bufnr, info)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(start_line, math.min(cursor[1] - 1, line_count - 1))
  local insert_row = opts.above == true and row or row + 1

  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, { "" })
    set_input_start(bufnr, info, start_line)
    vim.bo[bufnr].modified = false
  end)
  place_prompt(bufnr)
  pcall(vim.api.nvim_win_set_cursor, winid, { insert_row + 1, 0 })
  pcall(vim.cmd, "startinsert")

  return true
end

local function clear_current_input_line(bufnr, opts)
  opts = opts or {}
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return false
  end
  if not cursor_on_or_after_input(bufnr, info) then
    return false
  end

  local winid = vim.fn.bufwinid(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local input_start = input_start_line(bufnr, info)
  local input_lines = current_input_lines(bufnr, info)
  local row = math.max(input_start, cursor[1] - 1)
  local delete_row = opts.delete == true and #input_lines > 1
  local target_row = row

  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    if delete_row then
      vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, {})
      target_row = math.min(row, input_start + #input_lines - 2)
    else
      vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { "" })
    end
    set_input_start(bufnr, info, input_start)
    vim.bo[bufnr].modified = false
  end)
  place_prompt(bufnr)
  pcall(vim.api.nvim_win_set_cursor, winid, { target_row + 1, 0 })

  if opts.insert == true then
    focus_input(bufnr, info, { insert = true, position = "start" })
  end

  return true
end

local function normal_paste_register_text()
  local register = vim.v.register
  if type(register) ~= "string" or register == "" then
    register = '"'
  end

  local ok, text = pcall(vim.fn.getreg, register)
  if not ok or type(text) ~= "string" then
    return nil, "failed to read register " .. tostring(register)
  end

  return text, nil
end

paste_text_at_input_cursor = function(bufnr, info, text, opts)
  opts = opts or {}
  if type(text) ~= "string" or text == "" then
    return true
  end

  local winid = vim.fn.bufwinid(bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return nil, "Ark console buffer is not visible"
  end

  if cursor_before_input(bufnr, info) then
    focus_input(bufnr, info)
  end

  local start_line = input_start_line(bufnr, info)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row = math.max(start_line, cursor[1] - 1)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  row = math.min(row, math.max(start_line, line_count - 1))

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local col = math.max(0, math.min(cursor[2], #line))
  if opts.after == true and line ~= "" then
    col = math.min(#line, col + 1)
  end

  text = text:gsub("\n+$", "")
  if text == "" then
    return true
  end

  local pasted_lines = vim.split(text, "\n", { plain = true })
  if #pasted_lines == 0 then
    pasted_lines = { "" }
  end

  local before = line:sub(1, col)
  local after = line:sub(col + 1)
  local replacement = {}
  if #pasted_lines == 1 then
    replacement[1] = before .. pasted_lines[1] .. after
  else
    replacement[1] = before .. pasted_lines[1]
    for index = 2, #pasted_lines - 1 do
      replacement[#replacement + 1] = pasted_lines[index]
    end
    replacement[#replacement + 1] = pasted_lines[#pasted_lines] .. after
  end

  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, replacement)
    vim.bo[bufnr].modified = false
  end)
  place_prompt(bufnr)

  local target_row = row + #pasted_lines
  local target_col = #pasted_lines[#pasted_lines]
  if #pasted_lines == 1 then
    target_col = #before + #pasted_lines[1]
  end
  pcall(vim.api.nvim_win_set_cursor, winid, { target_row, target_col })

  return true
end

local function paste_register_into_input(bufnr, opts)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return false
  end

  local text, err = normal_paste_register_text()
  if not text then
    vim.notify(err or "failed to paste into Ark console", vim.log.levels.ERROR)
    return false
  end

  hide_blink_completion()
  local ok, paste_err = paste_text_at_input_cursor(bufnr, info, text, opts)
  if not ok then
    vim.notify(paste_err or "failed to paste into Ark console", vim.log.levels.ERROR)
    return false
  end
  return true
end

local function clamp_insert_cursor_to_input(bufnr)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return
  end
  if (tonumber(info.internal_edit) or 0) > 0 or info.reverting_protected_edit == true then
    return
  end
  if cursor_before_input(bufnr, info) then
    focus_input(bufnr, info)
  end
end

local function append_submitted_input_before_input(bufnr, lines, first_prompt)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or #lines == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    local start_line = input_start_line(bufnr, info)
    vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, lines)
    place_transcript_prompts(bufnr, start_line, #lines, first_prompt or "> ")
    set_input_start(bufnr, info, start_line + #lines)
    vim.bo[bufnr].modified = false
  end)
  place_prompt(bufnr)
end

local function text_lines(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    out[#out + 1] = line_text(item)
  end
  return out
end

local function apply_ansi_spans(bufnr, start_line, items)
  for offset, item in ipairs(items or {}) do
    local row = start_line + offset - 1
    for _, span in ipairs(line_spans(item)) do
      local hl_group = span.hl_group
      local start_col = tonumber(span.start_col)
      local end_col = tonumber(span.end_col)
      if type(hl_group) == "string" and start_col and end_col and end_col > start_col then
        vim.api.nvim_buf_set_extmark(bufnr, ansi_ns, row, start_col, {
          end_col = end_col,
          hl_group = hl_group,
          priority = 140,
          right_gravity = false,
          end_right_gravity = false,
        })
      end
    end
  end
end

local function append_before_input(bufnr, lines)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or #lines == 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local buffer_lines = text_lines(lines)
  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    local start_line = input_start_line(bufnr, info)
    vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, buffer_lines)
    apply_ansi_spans(bufnr, start_line, lines)
    set_input_start(bufnr, info, start_line + #lines)
    vim.bo[bufnr].modified = false
  end)
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
  if chunk == "" then
    return {}
  end

  local complete = consume_terminal_output(info, chunk)
  local text, prompt = strip_prompt_suffix(info.output_pending)
  if prompt then
    info.prompt_state = prompt.state
    info.prompt_text = prompt.text
    info.output_pending = text
    info.output_pending_spans = truncate_spans(info.output_pending_spans or {}, #text)
    info.output_cursor = math.min(tonumber(info.output_cursor) or #text, #text)
  end

  if prompt and info.output_pending ~= "" then
    complete[#complete + 1] = {
      text = info.output_pending,
      spans = info.output_pending_spans or {},
    }
    info.output_pending = ""
    info.output_pending_spans = {}
    info.output_cursor = 0
  end

  return transcript_lines_from_output(info, complete)
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

local function standalone_console(opts)
  return opts.standalone == true
    or vim.g.ark_console_standalone == true
    or vim.env.ARK_NVIM_CONSOLE_STANDALONE == "1"
end

local function terminal_ui_enabled(opts)
  return standalone_console(opts or {})
    or vim.g.ark_console_terminal_ui == true
    or vim.env.ARK_NVIM_CONSOLE_TERMINAL_UI == "1"
end

local function console_navigation_mode_enabled()
  local mode = vim.api.nvim_get_mode().mode
  if type(mode) ~= "string" or mode == "" then
    return false
  end

  local first = mode:sub(1, 1)
  return first == "n" or first == "v" or first == "V" or first == "\22"
end

local function apply_console_number_options(winid, enabled)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  if enabled == nil then
    enabled = console_navigation_mode_enabled()
  end
  vim.wo[winid].number = enabled
  vim.wo[winid].relativenumber = enabled
end

local function apply_console_conceal_options(winid, conceal_output_prefixes)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  if conceal_output_prefixes == nil then
    conceal_output_prefixes = not console_navigation_mode_enabled()
  end

  vim.wo[winid].conceallevel = conceal_output_prefixes and 2 or 0
  vim.wo[winid].concealcursor = ""
end

local function refresh_console_number_options(bufnr, enabled, conceal_output_prefixes)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    apply_console_number_options(winid, enabled)
    apply_console_conceal_options(winid, conceal_output_prefixes)
  end
end

local function install_console_number_autocmds(bufnr)
  local group = vim.api.nvim_create_augroup("ArkConsoleNumbers" .. tostring(bufnr), { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return true
      end

      refresh_console_number_options(bufnr, false, true)
    end,
    desc = "Hide Ark console relative line numbers in insert mode",
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "InsertLeave", "ModeChanged" }, {
    group = group,
    callback = function(event)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return true
      end

      local conceal_output_prefixes = nil
      if type(event) == "table" and event.event == "InsertLeave" then
        conceal_output_prefixes = false
      end
      refresh_console_number_options(bufnr, nil, conceal_output_prefixes)
    end,
    desc = "Toggle Ark console relative line numbers by mode",
  })
end

local function install_console_clipboard_keymaps(bufnr)
  local opts = {
    buffer = bufnr,
    desc = "Yank Ark console selection to system clipboard",
    silent = true,
  }
  vim.keymap.set("n", "y", '"+y', opts)
  vim.keymap.set("n", "Y", '"+Y', opts)
  vim.keymap.set("x", "y", '"+y', opts)
  vim.keymap.set("x", "Y", '"+Y', opts)
end

local function apply_console_window_options(winid, bufnr)
  if type(winid) ~= "number" or winid <= 0 or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  apply_console_number_options(winid)
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].colorcolumn = ""
  vim.wo[winid].cursorline = false
  vim.wo[winid].list = false
  vim.wo[winid].wrap = true
  vim.wo[winid].winbar = ""
  vim.wo[winid].statusline = " "
  apply_console_conceal_options(winid)
end

local function apply_terminal_ui(bufnr, opts)
  setup_highlights()
  vim.b[bufnr].ark_console_terminal_ui = terminal_ui_enabled(opts or {})
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].syntax = "r"
  vim.api.nvim_buf_call(bufnr, function()
    pcall(vim.cmd, "syntax match ArkConsoleOutput /^#>.*$/ contains=ArkConsoleOutputPrefix containedin=ALL")
    pcall(vim.cmd, "syntax match ArkConsoleOutputPrefix /^#> / conceal contained containedin=ArkConsoleOutput")
  end)

  local winid = vim.fn.bufwinid(bufnr)
  apply_console_window_options(winid, bufnr)

  if terminal_ui_enabled(opts or {}) then
    vim.o.showtabline = 0
    vim.o.laststatus = 0
    vim.o.statusline = " "
    vim.o.ruler = false
    vim.o.showcmd = false
    pcall(vim.api.nvim_set_option_value, "cmdheight", 0, { scope = "global" })
  end
end

local function console_info(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local info = state.buffers[bufnr]
  if type(info) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "not an Ark console buffer"
  end
  return info, nil, bufnr
end

local function reject_protected_edit(bufnr, info)
  if info.protected_edit_reject_pending == true then
    return
  end

  info.protected_edit_reject_pending = true
  vim.schedule(function()
    info.protected_edit_reject_pending = false
    if type(state.buffers[bufnr]) ~= "table" or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    restore_valid_snapshot(bufnr, info)
  end)
end

local function protect_transcript_edit(bufnr, firstline)
  local info = state.buffers[bufnr]
  if type(info) ~= "table" then
    return
  end
  if (tonumber(info.internal_edit) or 0) > 0 or info.reverting_protected_edit == true then
    return
  end
  if info.protected_edit_reject_pending == true then
    return
  end

  local input_start = tonumber(info.input_start) or 0
  if tonumber(firstline) and tonumber(firstline) < input_start then
    reject_protected_edit(bufnr, info)
  else
    refresh_valid_snapshot(bufnr, info)
  end
end

local function start_job(bufnr, opts, session_id, status_path)
  local runtime = opts.terminal or opts.tmux or {}
  local session_opts = type(opts.session) == "table" and opts.session or {}
  local backend = "nvim-console"
  if type(vim.env.TMUX) == "string"
    and vim.env.TMUX ~= ""
    and type(session_id) == "string"
    and not vim.startswith(session_id, "nvim_console__")
  then
    backend = type(session_opts.backend) == "string" and session_opts.backend or "tmux"
  end
  local launcher = runtime.launcher
  if type(launcher) ~= "string" or launcher == "" then
    return nil, "ark.nvim console requires a launcher"
  end

  local jobid = vim.fn.jobstart({ launcher }, {
    cwd = vim.fn.getcwd(),
    env = shell_env(runtime, session_id, status_path, backend),
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
        if standalone_console(opts or {}) then
          vim.cmd("qa!")
        end
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

local function create_buffer(opts)
  local bufnr
  if standalone_console(opts or {}) then
    pcall(vim.cmd, "silent! only")
    bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  else
    vim.cmd("botright split")
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, bufnr)
  end
  vim.b[bufnr].ark_console = true
  vim.bo[bufnr].buftype = ""
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].buflisted = false
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "r"
  vim.api.nvim_buf_set_name(bufnr, "ark-console://" .. tostring(vim.fn.getpid()) .. "/" .. tostring(bufnr) .. "/console.R")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
  vim.bo[bufnr].modified = false
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
      winid = vim.api.nvim_get_current_win()
    end
    apply_console_window_options(winid, existing)
    refresh_console_number_options(existing)
    return existing
  end

  local bufnr = create_buffer(opts)
  apply_terminal_ui(bufnr, opts)
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
    output_cursor = 0,
    pending_echo_lines = {},
    prompt_state = "top-level",
    rpc_socket = socket_path,
    rpc_running = false,
    session_id = session_id,
    status_path = session_runtime.status_file_path(runtime, session_id),
    status_timer = nil,
  }
  install_paste_handler()
  install_console_number_autocmds(bufnr)
  install_console_clipboard_keymaps(bufnr)
  set_input_start(bufnr, state.buffers[bufnr], 0)
  place_prompt(bufnr)
  refresh_valid_snapshot(bufnr, state.buffers[bufnr])

  local ok_server, server_result = pcall(vim.fn.serverstart, state.buffers[bufnr].rpc_socket)
  if ok_server and type(server_result) == "string" and server_result ~= "" then
    state.buffers[bufnr].rpc_socket = server_result
    state.buffers[bufnr].rpc_running = true
  else
    state.buffers[bufnr].rpc_running = false
    append_before_input(bufnr, { "#> failed to start Ark console RPC server: " .. tostring(server_result) })
  end
  state.buffers[bufnr].status_timer = start_status_publisher(bufnr)

  local jobid, err = start_job(bufnr, opts, session_id, state.buffers[bufnr].status_path)
  if not jobid then
    append_before_input(bufnr, { "#> " .. tostring(err) })
    return nil, err
  end
  state.buffers[bufnr].jobid = jobid
  publish_status(bufnr)

  if opts.auto_start_lsp ~= false then
    lsp.start(opts, bufnr, {
      wait_for_client = false,
    })
  end

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
  vim.keymap.set("i", "<Up>", function()
    M.history_prev(bufnr)
  end, { buffer = bufnr, desc = "Previous Ark console input" })
  vim.keymap.set("i", "<Down>", function()
    M.history_next(bufnr)
  end, { buffer = bufnr, desc = "Next Ark console input" })
  vim.keymap.set("n", "i", function()
    enter_insert_from_normal_i(bufnr)
  end, { buffer = bufnr, desc = "Enter insert mode in Ark console input" })
  for _, key in ipairs({ "a", "I", "A" }) do
    vim.keymap.set("n", key, function()
      local info = state.buffers[bufnr]
      if type(info) == "table" and cursor_before_input(bufnr, info) then
        focus_input(bufnr, info)
      end

      return key
    end, { buffer = bufnr, desc = "Enter insert mode in Ark console input", expr = true })
  end
  vim.keymap.set("n", "o", function()
    open_input_line_for_normal_edit(bufnr)
  end, { buffer = bufnr, desc = "Open line in Ark console input" })
  vim.keymap.set("n", "O", function()
    open_input_line_for_normal_edit(bufnr, { above = true })
  end, { buffer = bufnr, desc = "Open line above in Ark console input" })
  vim.keymap.set("n", "dd", function()
    clear_current_input_line(bufnr, { delete = true })
  end, { buffer = bufnr, desc = "Clear Ark console input line" })
  vim.keymap.set("n", "cc", function()
    clear_current_input_line(bufnr, { insert = true })
  end, { buffer = bufnr, desc = "Change Ark console input line" })
  vim.keymap.set("n", "p", function()
    paste_register_into_input(bufnr, { after = true })
  end, { buffer = bufnr, desc = "Paste into Ark console input" })
  vim.keymap.set("n", "P", function()
    paste_register_into_input(bufnr, { after = false })
  end, { buffer = bufnr, desc = "Paste before cursor in Ark console input" })
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

  vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMovedI" }, {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("ArkConsoleInputCursor" .. tostring(bufnr), { clear = true }),
    callback = function()
      clamp_insert_cursor_to_input(bufnr)
    end,
    desc = "Keep Ark console insert cursor in the active input",
  })

  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("ArkConsoleSignatureHelp" .. tostring(bufnr), { clear = true }),
    callback = function()
      maybe_show_signature_help(bufnr)
    end,
    desc = "Show Ark console signature help after argument triggers",
  })

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, changed_bufnr, _, firstline)
      protect_transcript_edit(changed_bufnr, firstline)
    end,
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

  restore_pending_protected_edit(bufnr, info)
  local end_line = vim.api.nvim_buf_line_count(bufnr)
  local lines = current_input_lines(bufnr, info)
  local text = table.concat(lines, "\n")
  if text:gsub("%s+", "") == "" then
    return true
  end

  local submitted_prompt = prompt_label(info)
  send_to_job(info, text)

  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, end_line, end_line, false, { "" })
    place_transcript_prompts(bufnr, input_start_line(bufnr, info), #lines, submitted_prompt)
    set_input_start(bufnr, info, end_line)
    vim.api.nvim_win_set_cursor(0, { input_start_line(bufnr, info) + 1, 0 })
    vim.bo[bufnr].modified = false
  end)
  place_prompt(bufnr)
  return true
end

function M.insert_newline(bufnr)
  local info, err, resolved_bufnr = console_info(bufnr)
  if not info then
    return nil, err
  end
  bufnr = resolved_bufnr
  restore_pending_protected_edit(bufnr, info)

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

  with_internal_edit(bufnr, info, function()
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before, after })
    vim.bo[bufnr].modified = false
    vim.api.nvim_win_set_cursor(winid, { row + 2, 0 })
  end)
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
  restore_pending_protected_edit(bufnr, info)
  set_current_input(bufnr, info, "")
  append_submitted_input_before_input(bufnr, vim.split(text, "\n", { plain = true }), prompt_label(info))
  send_to_job(info, text)
  place_prompt(bufnr)
  focus_input(bufnr, info, { insert = true })
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

  restore_pending_protected_edit(bufnr, info)
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
