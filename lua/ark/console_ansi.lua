local M = {}

local function color_hex(red, green, blue)
  red = math.max(0, math.min(255, tonumber(red) or 0))
  green = math.max(0, math.min(255, tonumber(green) or 0))
  blue = math.max(0, math.min(255, tonumber(blue) or 0))
  return string.format("#%02x%02x%02x", red, green, blue)
end

local function xterm_256_color(index, palette_color)
  index = tonumber(index)
  if not index or index < 0 or index > 255 then
    return nil
  end
  if index <= 15 then
    return palette_color(index)
  end
  if index <= 231 then
    local value = index - 16
    local levels = { 0, 95, 135, 175, 215, 255 }
    return color_hex(
      levels[math.floor(value / 36) + 1],
      levels[math.floor((value % 36) / 6) + 1],
      levels[(value % 6) + 1]
    )
  end

  local gray = 8 + ((index - 232) * 10)
  return color_hex(gray, gray, gray)
end

local function reset_style(style)
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
  return #params > 0 and params or { 0 }
end

local function apply_sgr(style, raw, palette_color)
  local params = parse_sgr_params(raw)
  local index = 1
  while index <= #params do
    local code = params[index]
    if code == 0 then
      reset_style(style)
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
      style.fg = palette_color(code - 30)
    elseif code >= 90 and code <= 97 then
      style.fg = palette_color((code - 90) + 8)
    elseif code == 38 then
      local mode = params[index + 1]
      if mode == 5 then
        style.fg = xterm_256_color(params[index + 2], palette_color)
        index = index + 2
      elseif mode == 2 then
        style.fg = color_hex(params[index + 2], params[index + 3], params[index + 4])
        index = index + 4
      end
    end
    index = index + 1
  end
end

function M.truncate_spans(spans, max_col)
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

local function set_span_range(spans, start_col, end_col, hl_group)
  local out = {}
  for _, span in ipairs(spans or {}) do
    local span_start = tonumber(span.start_col) or 0
    local span_end = tonumber(span.end_col) or 0
    if span_end <= start_col or span_start >= end_col then
      out[#out + 1] = span
    else
      if span_start < start_col then
        out[#out + 1] = { start_col = span_start, end_col = start_col, hl_group = span.hl_group }
      end
      if span_end > end_col then
        out[#out + 1] = { start_col = end_col, end_col = span_end, hl_group = span.hl_group }
      end
    end
  end
  if type(hl_group) == "string" and hl_group ~= "" then
    out[#out + 1] = { start_col = start_col, end_col = end_col, hl_group = hl_group }
  end

  table.sort(out, function(lhs, rhs)
    return lhs.start_col == rhs.start_col and lhs.end_col < rhs.end_col or lhs.start_col < rhs.start_col
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

function M.new(deps)
  assert(type(deps) == "table", "console ANSI decoder dependencies must be a table")
  assert(type(deps.palette_color) == "function", "console ANSI decoder requires palette_color()")
  assert(type(deps.style_group) == "function", "console ANSI decoder requires style_group()")

  return function(info, chunk)
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
      current, spans, cursor = "", {}, 0
      line_returned, overwrite_end = false, nil
    end

    local function clip_current_to_overwrite(force)
      if not line_returned or (not force and (overwrite_end or 0) == 0) then
        return
      end
      local max_col = math.max(0, math.min(overwrite_end or 0, #current))
      current = current:sub(1, max_col)
      spans = M.truncate_spans(spans, max_col)
      cursor = math.min(cursor, #current)
      line_returned, overwrite_end = false, nil
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
      cursor = cursor + text_len
      spans = set_span_range(spans, start_col, cursor, deps.style_group(style))
      if line_returned then
        overwrite_end = math.max(overwrite_end or 0, cursor)
      end
    end

    local function csi_final_offset(start)
      for offset = start, #chunk do
        local byte = chunk:byte(offset)
        if byte and byte >= 0x40 and byte <= 0x7e then
          return offset
        end
      end
    end

    local function osc_final_offset(start)
      for offset = start, #chunk do
        local byte = chunk:byte(offset)
        if byte == 0x07 then
          return offset
        end
        if byte == 0x1b and chunk:sub(offset + 1, offset + 1) == "\\" then
          return offset + 1
        end
      end
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
          if final_char == "m" then
            apply_sgr(style, chunk:sub(index + 2, final - 1), deps.palette_color)
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
        if chunk:sub(index + 1, index + 1) ~= "\n" then
          clip_current_to_overwrite(false)
          cursor, line_returned, overwrite_end = 0, true, 0
        end
      elseif char == "\n" then
        clip_current_to_overwrite(true)
        complete[#complete + 1] = { text = current, spans = spans }
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
end

return M
