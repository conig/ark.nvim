local M = {}

function M.line_text(item)
  if type(item) == "table" then
    return item.text or ""
  end
  return tostring(item or "")
end

function M.line_spans(item)
  if type(item) == "table" and type(item.spans) == "table" then
    return item.spans
  end
  return {}
end

local function split_plain_lines(text)
  local lines = {}
  for line in ((text or "") .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = { text = line, spans = {} }
  end
  return lines
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
end

function M.strip_prompt_suffix(text)
  local prompt = prompt_suffix(text)
  if not prompt then
    return text, nil
  end
  return text:sub(1, prompt.start_col - 1), prompt
end

local function pop_echo_line(info, line)
  local queue = type(info) == "table" and info.pending_echo_lines or nil
  if type(queue) ~= "table" or #queue == 0 or queue[1] ~= line then
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
end

local function prompt_only_line(line)
  return line:match("^%s*Browse%[[0-9]+%]>%s*$") ~= nil
    or line:match("^%s*debug>%s*$") ~= nil
    or line:match("^%s*recover>%s*$") ~= nil
    or line:match("^%s*>%s*$") ~= nil
    or line:match("^%s*%+%s*$") ~= nil
end

local function output_group(line, context_group)
  local trimmed = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed:match("^Error")
    or trimmed:match("^Execution halted")
    or trimmed:match("^Traceback")
    or trimmed:match("^Error:")
    or trimmed:match("^Error in ")
  then
    return "ArkConsoleOutputError"
  end
  if trimmed:match("^Warning")
    or trimmed:match("^Warning message")
    or trimmed:match("^Warning messages")
    or trimmed:match("^There were [0-9]+ warnings")
  then
    return "ArkConsoleOutputWarning"
  end
  if trimmed:match("^Loading required package:")
    or trimmed:match("^Attaching package:")
    or trimmed:match("^The following ")
    or trimmed:match("^Registered S3 ")
    or trimmed:match("^Registered S3 method")
    or trimmed:match("^Learn more ")
    or trimmed:match("^──")
  then
    return "ArkConsoleOutputMessage"
  end
  if context_group == "ArkConsoleOutputMessage"
    or context_group == "ArkConsoleOutputWarning"
    or context_group == "ArkConsoleOutputError"
  then
    return context_group
  end
  return "ArkConsoleOutputValue"
end

local function classify_spans(display_line, spans, context_group)
  local group = output_group(display_line, context_group)
  if type(group) ~= "string" or group == "" or type(display_line) ~= "string" or display_line == "" then
    return spans
  end
  local semantic_span = {
    start_col = 0,
    end_col = #display_line,
    hl_group = group,
    semantic = true,
  }
  if type(spans) == "table" and #spans > 0 then
    if group == "ArkConsoleOutputValue" then
      return spans
    end
    local merged = {}
    for _, span in ipairs(spans) do
      local copied = {}
      for key, value in pairs(span) do
        copied[key] = value
      end
      merged[#merged + 1] = copied
    end
    merged[#merged + 1] = semantic_span
    return merged
  end
  return { semantic_span }
end

function M.submitted_output_group(text)
  text = tostring(text or "")
  if text:find("[;\n]") then
    return nil
  end
  local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed:match("^message%s*%(") or trimmed:match("^[%w_.]+::message%s*%(") then
    return "ArkConsoleOutputMessage"
  end
  if trimmed:match("^warning%s*%(") or trimmed:match("^[%w_.]+::warning%s*%(") then
    return "ArkConsoleOutputWarning"
  end
  if trimmed:match("^stop%s*%(") or trimmed:match("^[%w_.]+::stop%s*%(") then
    return "ArkConsoleOutputError"
  end
end

function M.styled_chunks(text, spans, default_hl)
  text, spans = text or "", spans or {}
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
    chunks[1] = { text, default_hl }
  end
  return chunks
end

function M.lines_from_output(info, output)
  if type(output) == "string" then
    output = split_plain_lines(output)
  end

  local lines = {}
  for _, item in ipairs(output or {}) do
    local line = M.line_text(item)
    local stripped, prefix_len = prompt_prefix_stripped(line)
    local plus_stripped = line:gsub("^%s*%+%s+", "", 1)
    local display_line = stripped or line
    local item_spans = M.line_spans(item)
    local display_spans = stripped and strip_span_prefix(item_spans, prefix_len) or item_spans
    local trimmed = display_line:gsub("^%s+", ""):gsub("%s+$", "")
    local is_echo = pop_echo_line(info, line)
      or (stripped ~= nil and pop_echo_line(info, stripped))
      or (plus_stripped ~= line and pop_echo_line(info, plus_stripped))
    if trimmed ~= "" and not prompt_only_line(line) and not is_echo then
      display_spans = classify_spans(display_line, display_spans, info.pending_output_group)
      lines[#lines + 1] = {
        text = "#> " .. display_line,
        spans = offset_spans(display_spans, 3),
      }
    end
  end
  return lines
end

return M
