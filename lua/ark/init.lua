local blink = require("ark.blink")
local bridge = require("ark.bridge")
local config = require("ark.config")
local dev = require("ark.dev")
local lsp = require("ark.lsp")
local session_backend = require("ark.session")
local snippets = require("ark.snippets")
local view = require("ark.view")
local uv = vim.uv or vim.loop

local M = {}

local did_setup = false
local options = nil
local startup_tokens = {}
local startup_traces = {}
local pending_session_sync = 0
local help_float_ns = vim.api.nvim_create_namespace("ArkHelpFloat")
local help_filetype = "arkhelp"
local is_ark_buffer
local ensure_bridge_runtime

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function wallclock_ms()
  if uv and type(uv.gettimeofday) == "function" then
    local sec, usec = uv.gettimeofday()
    if type(sec) == "number" and type(usec) == "number" then
      return (sec * 1000) + math.floor(usec / 1000)
    end
  end

  return math.floor(os.time() * 1000)
end

local function iso_timestamp(ms)
  if type(ms) ~= "number" then
    return nil
  end

  local sec = math.floor(ms / 1000)
  local millis = ms - (sec * 1000)
  return os.date("%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03d", millis)
end

local function format_ms(value)
  if type(value) ~= "number" then
    return nil
  end

  return string.format("+%dms", math.max(0, math.floor(value)))
end

local function tracked_startup_file(bufnr)
  local path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  return path ~= "" and path or nil
end

local function startup_log_path()
  local runtime_config = session_backend.runtime_config(options)
  if type(runtime_config) ~= "table" then
    return nil
  end

  local status = session_backend.startup_status_authoritative(options)
  if type(status) ~= "table" then
    return nil
  end

  return type(status.log_path) == "string" and status.log_path or nil
end

local function append_startup_log(event, fields)
  local path = startup_log_path()
  if type(path) ~= "string" or path == "" then
    return nil
  end

  local elapsed_ms = nil
  for _, field in ipairs(fields or {}) do
    if type(field) == "table" and field.key == "startup_elapsed_ms" and type(field.value) == "number" then
      elapsed_ms = field.value
      break
    end
  end

  local ts = iso_timestamp(wallclock_ms())
  local elapsed = format_ms(elapsed_ms)
  local line = elapsed and string.format("[%s %s] [nvim-startup] %s", ts, elapsed, event)
    or string.format("[%s] [nvim-startup] %s", ts, event)
  for _, field in ipairs(fields or {}) do
    if type(field) == "table" and type(field.key) == "string" and field.key ~= "" and field.value ~= nil then
      local rendered = field.value
      if type(rendered) == "number" and field.key:sub(-3) == "_ms" then
        rendered = format_ms(rendered)
      end
      line = line .. string.format(" %s=%s", field.key, tostring(rendered))
    end
  end

  local dir = vim.fs.dirname(path)
  if type(dir) == "string" and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
  vim.fn.writefile({ line }, path, "a")
  return path
end

local function cleanup_startup_trace(bufnr)
  startup_traces[bufnr] = nil
end

local function ensure_startup_trace_cleanup(bufnr)
  if startup_traces[bufnr] and startup_traces[bufnr].cleanup_registered == true then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    cleanup_startup_trace(bufnr)
    return
  end

  if not startup_traces[bufnr] then
    return
  end

  startup_traces[bufnr].cleanup_registered = true
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      cleanup_startup_trace(bufnr)
    end,
  })
end

local function startup_unlocked(bufnr)
  local trace = startup_traces[bufnr]
  if type(trace) ~= "table" then
    return true
  end
  if startup_tokens[bufnr] ~= trace.token then
    cleanup_startup_trace(bufnr)
    return true
  end

  return trace.main_buffer_unlocked == true
end

local function record_startup_unlock(bufnr, source, unlock_opts)
  local trace = startup_traces[bufnr]
  if type(trace) ~= "table" or trace.main_buffer_unlocked == true then
    return
  end
  if startup_tokens[bufnr] ~= trace.token then
    cleanup_startup_trace(bufnr)
    return
  end

  unlock_opts = unlock_opts or {}

  local unlocked_at_ms = wallclock_ms()
  trace.file = trace.file or tracked_startup_file(bufnr)
  trace.filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or trace.filetype
  trace.log_path = startup_log_path() or trace.log_path
  trace.main_buffer_unlocked = true
  trace.main_buffer_unlock_at_iso = iso_timestamp(unlocked_at_ms)
  trace.main_buffer_unlock_at_ms = unlocked_at_ms
  trace.main_buffer_unlock_elapsed_ms = math.max(0, monotonic_ms() - trace.started_mono_ms)
  trace.main_buffer_unlock_source = source or "SafeState"
  if type(unlock_opts.post_lsp_bootstrap_unlock_ms) == "number" then
    trace.post_lsp_bootstrap_unlock_ms = math.max(0, unlock_opts.post_lsp_bootstrap_unlock_ms)
  end

  trace.log_path = append_startup_log("main_buffer_unlocked", {
    { key = "bufnr", value = bufnr },
    { key = "filetype", value = trace.filetype },
    { key = "file", value = trace.file },
    { key = "startup_elapsed_ms", value = trace.main_buffer_unlock_elapsed_ms },
    { key = "post_lsp_bootstrap_unlock_ms", value = trace.post_lsp_bootstrap_unlock_ms },
    { key = "source", value = trace.main_buffer_unlock_source },
  }) or trace.log_path
end

local function begin_startup_trace(bufnr, token)
  local started_at_ms = wallclock_ms()
  startup_traces[bufnr] = {
    bufnr = bufnr,
    cleanup_registered = false,
    file = tracked_startup_file(bufnr),
    filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil,
    log_path = startup_log_path(),
    started_at_iso = iso_timestamp(started_at_ms),
    started_at_ms = started_at_ms,
    started_mono_ms = monotonic_ms(),
    token = token,
  }
  ensure_startup_trace_cleanup(bufnr)
  return startup_traces[bufnr]
end

local function lsp_status_ready_for_safe_state(bufnr)
  local status = lsp.status(options, bufnr, {
    cache_ttl_ms = 50,
    throttle_ms = 25,
    timeout_ms = 50,
  })
  if type(status) ~= "table" or status.available ~= true then
    return false, status
  end

  if options.auto_start_pane ~= true then
    return true, status
  end

  local detached_status = type(status.detachedSessionStatus) == "table" and status.detachedSessionStatus or nil
  if type(detached_status) ~= "table" then
    return false, status
  end

  return detached_status.lastSessionUpdateStatus == "ready"
    and type(detached_status.lastBootstrapSuccessMs) == "number",
    status
end

local function startup_ready_for_safe_state(bufnr)
  if not options or type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return false, nil, nil
  end
  if not vim.tbl_contains(options.filetypes or {}, vim.bo[bufnr].filetype) then
    return false, nil, nil
  end

  local backend_snapshot = nil
  if options.auto_start_pane == true then
    backend_snapshot = session_backend.startup_snapshot(options, {
      include_prompt_ready = false,
      validate_bridge = false,
    })
    local startup_status = type(backend_snapshot) == "table" and backend_snapshot.startup_status or nil
    if type(backend_snapshot) ~= "table"
      or backend_snapshot.bridge_ready ~= true
      or type(startup_status) ~= "table"
      or startup_status.repl_ready ~= true
    then
      return false, backend_snapshot, nil
    end
  end

  if options.auto_start_lsp ~= true then
    return true, backend_snapshot, nil
  end

  local lsp_ready, lsp_status = lsp_status_ready_for_safe_state(bufnr)
  return lsp_ready, backend_snapshot, lsp_status
end

local function mark_startup_safe_state(bufnr, source)
  if startup_unlocked(bufnr) then
    return
  end

  local ready, _, lsp_status = startup_ready_for_safe_state(bufnr)
  if not ready then
    return
  end

  local post_lsp_bootstrap_unlock_ms = nil
  local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
  if type(detached_status) == "table" and type(detached_status.lastBootstrapSuccessMs) == "number" then
    post_lsp_bootstrap_unlock_ms = math.max(0, wallclock_ms() - detached_status.lastBootstrapSuccessMs)
  end
  record_startup_unlock(bufnr, source, {
    post_lsp_bootstrap_unlock_ms = post_lsp_bootstrap_unlock_ms,
  })
end

local function startup_status(bufnr)
  if type(bufnr) ~= "number" then
    bufnr = vim.api.nvim_get_current_buf()
  end

  if #vim.api.nvim_list_uis() == 0 then
    mark_startup_safe_state(bufnr, "HeadlessStatusPoll")
  end

  local trace = startup_traces[bufnr]
  if type(trace) ~= "table" then
    return {
      tracked = false,
      bufnr = bufnr,
      file = tracked_startup_file(bufnr),
      filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil,
      log_path = startup_log_path(),
      main_buffer_unlocked = false,
    }
  end

  return {
    tracked = true,
    bufnr = trace.bufnr,
    file = trace.file,
    filetype = trace.filetype,
    log_path = trace.log_path or startup_log_path(),
    main_buffer_unlocked = trace.main_buffer_unlocked == true,
    main_buffer_unlock_at_iso = trace.main_buffer_unlock_at_iso,
    main_buffer_unlock_at_ms = trace.main_buffer_unlock_at_ms,
    main_buffer_unlock_elapsed_ms = trace.main_buffer_unlock_elapsed_ms,
    main_buffer_unlock_source = trace.main_buffer_unlock_source,
    post_lsp_bootstrap_unlock_ms = trace.post_lsp_bootstrap_unlock_ms,
    started_at_iso = trace.started_at_iso,
    started_at_ms = trace.started_at_ms,
  }
end

local function r_string_literal(value)
  return '"' .. tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function help_expression(topic)
  local package_name, help_name = topic:match("^([A-Za-z.][A-Za-z0-9._]*):::([A-Za-z.][A-Za-z0-9._]*)$")
  if not package_name or not help_name then
    package_name, help_name = topic:match("^([A-Za-z.][A-Za-z0-9._]*)::([A-Za-z.][A-Za-z0-9._]*)$")
  end
  if package_name and help_name then
    return string.format(
      'utils::help(%s, package = %s, help_type = "text")',
      r_string_literal(help_name),
      r_string_literal(package_name)
    )
  end

  return string.format('utils::help(%s, help_type = "text")', r_string_literal(topic))
end

local function split_lines(text)
  local normalized = tostring(text or ""):gsub("\r\n", "\n")
  return vim.split(normalized, "\n", { plain = true })
end

local function trim_empty_edges(lines, start_line, end_line)
  while start_line <= end_line and vim.trim(lines[start_line] or "") == "" do
    start_line = start_line + 1
  end

  while end_line >= start_line and vim.trim(lines[end_line] or "") == "" do
    end_line = end_line - 1
  end

  return start_line, end_line
end

local function color_value(value)
  if type(value) == "number" then
    return string.format("#%06x", value)
  end

  if type(value) == "string" and value ~= "" then
    return value
  end

  return nil
end

local function hex_to_rgb(value)
  value = color_value(value)
  if type(value) ~= "string" then
    return nil
  end

  local hex = value:gsub("^#", "")
  if #hex ~= 6 then
    return nil
  end

  local red = tonumber(hex:sub(1, 2), 16)
  local green = tonumber(hex:sub(3, 4), 16)
  local blue = tonumber(hex:sub(5, 6), 16)
  if not red or not green or not blue then
    return nil
  end

  return { red, green, blue }
end

local function rgb_to_hex(rgb)
  if type(rgb) ~= "table" or #rgb < 3 then
    return nil
  end

  return string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])
end

local function blend_colors(base, target, alpha)
  local base_rgb = hex_to_rgb(base)
  local target_rgb = hex_to_rgb(target)
  if not base_rgb or not target_rgb then
    return color_value(base) or color_value(target)
  end

  alpha = math.max(0, math.min(alpha or 0.5, 1))
  local blended = {}
  for index = 1, 3 do
    blended[index] = math.floor((base_rgb[index] * (1 - alpha)) + (target_rgb[index] * alpha) + 0.5)
  end

  return rgb_to_hex(blended)
end

local function color_distance(left, right)
  local left_rgb = hex_to_rgb(left)
  local right_rgb = hex_to_rgb(right)
  if not left_rgb or not right_rgb then
    return math.huge
  end

  local distance = 0
  for index = 1, 3 do
    distance = distance + math.abs(left_rgb[index] - right_rgb[index])
  end
  return distance
end

local function relative_luminance(value)
  local rgb = hex_to_rgb(value)
  if not rgb then
    return 0
  end

  return (0.2126 * rgb[1]) + (0.7152 * rgb[2]) + (0.0722 * rgb[3])
end

local function ensure_distinct_bg(candidate, base, accent)
  candidate = color_value(candidate)
  base = color_value(base)
  accent = color_value(accent)
  if not candidate then
    candidate = base
  end
  if not candidate then
    return accent
  end
  if not base then
    return candidate
  end

  if color_distance(candidate, base) >= 12 then
    return candidate
  end

  if accent and color_distance(accent, base) >= 24 then
    return blend_colors(base, accent, 0.18)
  end

  if relative_luminance(base) >= 128 then
    return blend_colors(base, "#000000", 0.12)
  end

  return blend_colors(base, "#ffffff", 0.12)
end

local function ensure_code_surface(candidate, base)
  candidate = color_value(candidate)
  base = color_value(base)
  if not candidate then
    candidate = base
  end
  if not candidate then
    return nil
  end
  if not base then
    return candidate
  end

  if color_distance(candidate, base) >= 24 then
    return candidate
  end

  if relative_luminance(base) >= 128 then
    return blend_colors(base, "#000000", 0.18)
  end

  return blend_colors(base, "#000000", 0.12)
end

local function get_hl_color(name, key)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or type(hl) ~= "table" then
    return nil
  end

  return color_value(hl[key])
end

local function first_color(...)
  for index = 1, select("#", ...) do
    local value = color_value(select(index, ...))
    if value then
      return value
    end
  end
  return nil
end

local function help_palette()
  local colors = {}
  local ok, base46 = pcall(require, "base46")
  if ok and type(base46) == "table" and type(base46.get_theme_tb) == "function" then
    colors = base46.get_theme_tb("base_30") or {}
  end

  local normal_bg = first_color(get_hl_color("NormalFloat", "bg"), get_hl_color("Normal", "bg"), "#1f1f1f")
  local normal_fg = first_color(get_hl_color("NormalFloat", "fg"), get_hl_color("Normal", "fg"), "#e6e6e6")
  local section_bg = first_color(
    colors.one_bg3,
    colors.one_bg2,
    colors.line,
    get_hl_color("CursorLine", "bg"),
    get_hl_color("Visual", "bg"),
    normal_bg
  )
  local arguments_bg = first_color(
    colors.one_bg2,
    colors.one_bg3,
    colors.black2,
    colors.line,
    get_hl_color("ColorColumn", "bg"),
    normal_bg
  )
  local accent_bg = first_color(
    colors.sun,
    colors.yellow,
    colors.orange,
    colors.baby_pink,
    get_hl_color("Title", "fg"),
    get_hl_color("Special", "fg"),
    normal_bg
  )
  local code_bg = first_color(
    get_hl_color("ColorColumn", "bg"),
    get_hl_color("RenderMarkdownCode", "bg"),
    colors.black2,
    colors.darker_black,
    colors.one_bg,
    colors.one_bg2,
    colors.line,
    section_bg,
    normal_bg
  )
  code_bg = color_value(code_bg)
  if not code_bg then
    code_bg = blend_colors(normal_bg, "#000000", relative_luminance(normal_bg) >= 128 and 0.18 or 0.12)
  elseif color_distance(code_bg, normal_bg) < 12 then
    code_bg = blend_colors(normal_bg, "#000000", relative_luminance(normal_bg) >= 128 and 0.18 or 0.12)
  end

  return {
    normal_bg = normal_bg,
    normal_fg = normal_fg,
    muted_fg = first_color(
      colors.grey_fg,
      colors.light_grey,
      get_hl_color("Comment", "fg"),
      normal_fg
    ),
    section_bg = section_bg,
    arguments_bg = arguments_bg,
    code_bg = code_bg,
    accent_bg = accent_bg,
    accent_fg = first_color(
      colors.black,
      colors.darker_black,
      get_hl_color("Normal", "bg"),
      "#111111",
      normal_fg
    ),
    label_fg = first_color(
      colors.sun,
      colors.yellow,
      colors.orange,
      colors.baby_pink,
      get_hl_color("Title", "fg"),
      normal_fg
    ),
  }
end

local function ensure_help_highlights()
  local palette = help_palette()

  vim.api.nvim_set_hl(0, "ArkHelpTitle", {
    bg = palette.accent_bg,
    fg = palette.accent_fg,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "ArkHelpSectionHeader", {
    bg = palette.section_bg,
    fg = palette.normal_fg,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "ArkHelpUsageHeader", {
    bg = palette.section_bg,
    fg = palette.normal_fg,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "ArkHelpUsageBody", {
    bg = palette.code_bg,
  })
  vim.api.nvim_set_hl(0, "ArkHelpCodeFence", {
    bg = ensure_code_surface(blend_colors(palette.code_bg, palette.section_bg, 0.45), palette.code_bg),
    fg = palette.muted_fg,
    italic = true,
  })
  vim.api.nvim_set_hl(0, "ArkHelpArgumentsHeader", {
    bg = palette.accent_bg,
    fg = palette.accent_fg,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "ArkHelpArgumentsBody", {
    bg = palette.arguments_bg,
  })
  vim.api.nvim_set_hl(0, "ArkHelpArgumentName", {
    fg = palette.label_fg,
    bold = true,
  })
  vim.api.nvim_set_hl(0, "ArkHelpReference", {
    fg = palette.label_fg,
    underline = true,
  })
end

local function help_section_name(line)
  return line:match("^([A-Z][A-Za-z ]+):$")
end

local function add_line_highlight(buf, line_index, group, priority)
  vim.api.nvim_buf_set_extmark(buf, help_float_ns, line_index, 0, {
    line_hl_group = group,
    hl_eol = true,
    priority = priority or 100,
  })
end

local function add_range_highlight(buf, start_line, end_line, lines, group, priority)
  if not start_line or not end_line or start_line > end_line then
    return
  end

  local end_text = lines[end_line] or ""
  vim.api.nvim_buf_set_extmark(buf, help_float_ns, start_line - 1, 0, {
    end_row = end_line - 1,
    end_col = #end_text,
    hl_group = group,
    hl_eol = true,
    priority = priority or 100,
  })
end

local function help_reference_target(reference)
  if type(reference) ~= "table" or type(reference.topic) ~= "string" or reference.topic == "" then
    return nil
  end

  if type(reference.package) == "string" and reference.package ~= "" then
    return string.format("%s::%s", reference.package, reference.topic)
  end

  return reference.topic
end

local function is_navigable_reference_label(label)
  if type(label) ~= "string" then
    return false
  end

  label = vim.trim(label)
  if label == "" then
    return false
  end

  if label:find("%(") or label:find("::", 1, true) or label:find("%?") or label:find("_", 1, true) then
    return true
  end

  return #label >= 3 and label:match("[%a][%a][%a]") ~= nil
end

local function build_help_reference_matches(lines, references)
  local grouped = {}

  for _, reference in ipairs(references or {}) do
    local label = type(reference.label) == "string" and vim.trim(reference.label) or ""
    local target = help_reference_target(reference)
    if label ~= "" and target and is_navigable_reference_label(label) then
      local existing = grouped[label]
      if not existing then
        grouped[label] = {
          label = label,
          target = target,
          ambiguous = false,
        }
      elseif existing.target ~= target then
        existing.ambiguous = true
      end
    end
  end

  local labels = {}
  for label, entry in pairs(grouped) do
    if not entry.ambiguous then
      labels[#labels + 1] = label
    end
  end

  table.sort(labels, function(left, right)
    if #left == #right then
      return left < right
    end
    return #left > #right
  end)

  local matches = {}
  for line_index, line in ipairs(lines) do
    local occupied = {}

    for _, label in ipairs(labels) do
      local start_col = 1
      while true do
        local match_start, match_end = line:find(label, start_col, true)
        if not match_start then
          break
        end

        local overlaps = false
        for index = match_start, match_end do
          if occupied[index] then
            overlaps = true
            break
          end
        end

        if not overlaps then
          for index = match_start, match_end do
            occupied[index] = true
          end

          matches[#matches + 1] = {
            line = line_index,
            start_col = match_start - 1,
            end_col = match_end,
            label = label,
            target = grouped[label].target,
          }
        end

        start_col = match_start + 1
      end
    end
  end

  return matches
end

local function reference_under_cursor(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2]

  for _, match in ipairs(vim.b[buf].ark_help_references or {}) do
    if match.line == line and col >= match.start_col and col < match.end_col then
      return match
    end
  end
end

local function render_help_display(raw_lines)
  local rendered = {
    lines = {},
    code_blocks = {},
  }

  local sections = {}
  for index, line in ipairs(raw_lines) do
    local header = help_section_name(line)
    if header then
      sections[#sections + 1] = { name = header, line = index }
    end
  end

  local cursor = 1
  for index, section in ipairs(sections) do
    local next_line = sections[index + 1] and sections[index + 1].line or (#raw_lines + 1)
    local is_code_section = section.name == "Usage" or section.name == "Examples"
    if not is_code_section then
      goto continue
    end

    for raw_index = cursor, section.line do
      rendered.lines[#rendered.lines + 1] = raw_lines[raw_index]
    end

    local body_start, body_end = trim_empty_edges(raw_lines, section.line + 1, next_line - 1)
    local block = {
      name = section.name,
      header_line = #rendered.lines,
      fence_start = #rendered.lines + 1,
    }

    rendered.lines[#rendered.lines + 1] = "```r"
    block.body_start = #rendered.lines + 1

    if body_start <= body_end then
      for raw_index = body_start, body_end do
        rendered.lines[#rendered.lines + 1] = raw_lines[raw_index]
      end
    end

    block.body_end = #rendered.lines
    block.fence_end = #rendered.lines + 1
    rendered.lines[#rendered.lines + 1] = "```"
    rendered.code_blocks[#rendered.code_blocks + 1] = block

    if next_line <= #raw_lines then
      rendered.lines[#rendered.lines + 1] = ""
    end

    cursor = next_line

    ::continue::
  end

  for raw_index = cursor, #raw_lines do
    rendered.lines[#rendered.lines + 1] = raw_lines[raw_index]
  end

  if #rendered.lines == 0 then
    rendered.lines = { "" }
  end

  return rendered
end

local function apply_help_highlights(buf, rendered, references)
  local lines = rendered.lines
  ensure_help_highlights()
  vim.api.nvim_buf_clear_namespace(buf, help_float_ns, 0, -1)

  local title_line = nil
  local sections = {}
  local code_blocks_by_header = {}

  for _, block in ipairs(rendered.code_blocks or {}) do
    code_blocks_by_header[block.header_line] = block
  end

  for index, line in ipairs(lines) do
    if title_line == nil and line ~= "" then
      title_line = index
    end

    local header = help_section_name(line)
    if header then
      sections[#sections + 1] = { name = header, line = index }
    end
  end

  if title_line and (not sections[1] or title_line < sections[1].line) then
    add_line_highlight(buf, title_line - 1, "ArkHelpTitle", 250)
  end

  for index, section in ipairs(sections) do
    local next_line = sections[index + 1] and sections[index + 1].line or (#lines + 1)
    local body_start = section.line + 1
    local body_end = next_line - 1

    if section.name == "Arguments" then
      add_line_highlight(buf, section.line - 1, "ArkHelpArgumentsHeader", 220)
      for line_index = body_start, body_end do
        add_line_highlight(buf, line_index - 1, "ArkHelpArgumentsBody", 110)

        local line = lines[line_index] or ""
        local start_col, end_col = line:find("^%s*[%w._]+:")
        if not start_col then
          start_col, end_col = line:find("^%s*%.%.%.:")
        end
        if start_col and end_col then
          vim.api.nvim_buf_add_highlight(buf, help_float_ns, "ArkHelpArgumentName", line_index - 1, start_col - 1, end_col)
        end
      end
    elseif section.name == "Usage" or section.name == "Examples" then
      add_line_highlight(buf, section.line - 1, "ArkHelpUsageHeader", 210)
      local block = code_blocks_by_header[section.line]
      if block then
        add_range_highlight(buf, block.fence_start, block.fence_start, lines, "ArkHelpCodeFence", 120)
        if block.body_start <= block.body_end then
          add_range_highlight(buf, block.body_start, block.body_end, lines, "ArkHelpUsageBody", 105)
        end
        add_range_highlight(buf, block.fence_end, block.fence_end, lines, "ArkHelpCodeFence", 120)
      else
        add_range_highlight(buf, body_start, body_end, lines, "ArkHelpUsageBody", 105)
      end
    else
      add_line_highlight(buf, section.line - 1, "ArkHelpSectionHeader", 200)
    end
  end

  local matches = build_help_reference_matches(lines, references)
  for _, match in ipairs(matches) do
    vim.api.nvim_buf_set_extmark(buf, help_float_ns, match.line - 1, match.start_col, {
      end_col = match.end_col,
      hl_group = "ArkHelpReference",
      priority = 320,
    })
  end

  vim.b[buf].ark_help_references = matches
end

local function open_readonly_float(text, opts)
  opts = opts or {}
  local rendered = render_help_display(split_lines(text))
  local lines = rendered.lines

  local max_width = 0
  for _, line in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - vim.o.cmdheight
  local width = math.max(72, math.min(math.max(max_width + 4, 72), math.floor(editor_width * 0.9)))
  local height = math.max(10, math.min(#lines, math.floor(editor_height * 0.85)))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = help_filetype
  local treesitter_started = pcall(vim.treesitter.start, buf, "markdown")
  vim.b[buf].ark_help_treesitter = treesitter_started
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(1, math.floor((editor_height - height) / 2) - 1),
    col = math.max(0, math.floor((editor_width - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false
  vim.wo[win].conceallevel = 0
  vim.wo[win].concealcursor = ""

  apply_help_highlights(buf, rendered, opts.references or {})

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.b[buf].ark_help_source_bufnr = opts.source_bufnr
  vim.b[buf].ark_help_buffer = true

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", function()
    local match = reference_under_cursor(buf)
    if not match then
      return
    end

    close()

    if type(opts.on_follow) == "function" then
      opts.on_follow(match.target)
    end
  end, { buffer = buf, nowait = true, silent = true })

  return buf, win
end

local function wait_for_help_runtime(bufnr)
  local runtime_config = session_backend.runtime_config(options) or {}
  local timeout_ms = tonumber(runtime_config.bridge_wait_ms or 5000) or 5000

  return vim.wait(timeout_ms, function()
    local tmux_status = session_backend.status(options)
    local lsp_status = lsp.status(options, bufnr)
    local bridge_ready = type(tmux_status) == "table" and tmux_status.bridge_ready == true
    local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
    return bridge_ready
      and type(lsp_status) == "table"
      and lsp_status.available == true
      and lsp_status.sessionBridgeConfigured == true
      and type(detached_status) == "table"
      and detached_status.lastSessionUpdateStatus == "ready"
  end, 100, false)
end

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function ensure_runtime_ready(bufnr, label)
  bufnr = resolve_bufnr(bufnr)
  label = label or "ark.nvim runtime"

  if not is_ark_buffer(bufnr) then
    return nil, label .. " requires an R-family buffer"
  end

  lsp.start(options, bufnr)

  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end

  local _, pane_err = session_backend.start(options)
  if pane_err then
    return nil, pane_err
  end

  lsp.sync_sessions(options, bufnr)

  if not wait_for_help_runtime(bufnr) then
    return nil, label .. " bridge is not ready"
  end

  return true
end

is_ark_buffer = function(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and options ~= nil
    and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ark.nvim" })
end

local function merged_opts(base, opts)
  return vim.tbl_deep_extend("force", config.defaults(), base or {}, opts or {})
end

local function ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

ensure_bridge_runtime = function(bridge_opts)
  bridge_opts = bridge_opts or {}
  local runtime_config = session_backend.runtime_config(options)
  if type(runtime_config) ~= "table" then
    return true
  end

  local completed = nil
  local ok, err = bridge.ensure_current_runtime(runtime_config, {
    on_build_complete = function(result)
      completed = result
      if type(bridge_opts.on_build_complete) == "function" then
        bridge_opts.on_build_complete(result)
      end
    end,
    user_initiated = bridge_opts.user_initiated == true,
  })
  if ok then
    return true
  end

  local message = type(err) == "table" and err.message or err
  if bridge_opts.wait_on_pending == true and type(err) == "table" and err.kind == "build_pending" then
    local timeout_ms = tonumber(bridge_opts.timeout_ms or 20000) or 20000
    local waited = vim.wait(timeout_ms, function()
      return type(completed) == "table"
    end, 50, false)
    local failure_message = (type(completed) == "table" and completed.error) or message
    if not waited or completed.ok ~= true then
      if bridge_opts.notify ~= false and type(failure_message) == "string" and failure_message ~= "" then
        notify(failure_message, vim.log.levels.ERROR)
      end
      return nil, failure_message
    end

    local retry_ok, retry_err = ensure_bridge_runtime(vim.tbl_extend("force", bridge_opts, {
      wait_on_pending = false,
      on_build_complete = nil,
      notify = false,
    }))
    if not retry_ok and bridge_opts.notify ~= false and type(retry_err) == "string" and retry_err ~= "" then
      notify(retry_err, vim.log.levels.ERROR)
    end
    return retry_ok, retry_err
  end

  if bridge_opts.notify ~= false and type(message) == "string" and message ~= "" then
    notify(message, bridge_opts.pending_level or vim.log.levels.INFO)
  end

  return nil, message
end

local function sync_sessions_soon()
  pending_session_sync = pending_session_sync + 1
  local token = pending_session_sync

  vim.schedule(function()
    if token ~= pending_session_sync then
      return
    end
    if not options then
      return
    end

    lsp.sync_sessions(options, nil, { fast = true })
  end)
end

local function start_managed_buffer(bufnr)
  if not options or type(bufnr) ~= "number" then
    return
  end

  local token = (startup_tokens[bufnr] or 0) + 1
  startup_tokens[bufnr] = token
  begin_startup_trace(bufnr, token)

  local function can_start_buffer()
    return startup_tokens[bufnr] == token
      and vim.api.nvim_buf_is_valid(bufnr)
      and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
  end

  local function start_sync_lsp_later()
    vim.schedule(function()
      if not can_start_buffer() then
        return
      end

      lsp.start(options, bufnr)
    end)
  end

  local function prewarm_lsp()
    if not options.auto_start_lsp then
      return
    end

    if options.auto_start_pane and not options.async_startup and type(lsp.prewarm) == "function" then
      lsp.prewarm(options, bufnr)
      return
    end

    lsp.start_async(options, bufnr)
  end

  local function start_pane_and_sync()
    if not can_start_buffer() then
      return
    end

    local _, pane_err = session_backend.start(options)
    if pane_err then
      notify(pane_err, vim.log.levels.WARN)
      return
    end

    if options.auto_start_lsp and (options.auto_start_pane or not options.async_startup) then
      start_sync_lsp_later()
    end
  end

  local function start_buffer()
    if not can_start_buffer() then
      return
    end

    prewarm_lsp()

    if options.auto_start_pane then
      local bridge_ok = ensure_bridge_runtime({
        on_build_complete = function(result)
          if type(result) ~= "table" or result.ok ~= true then
            return
          end

          vim.schedule(function()
            start_pane_and_sync()
          end)
        end,
      })
      if bridge_ok then
        start_pane_and_sync()
      end
      return
    end

    if options.auto_start_lsp and not options.async_startup then
      start_sync_lsp_later()
    end
  end

  if options.async_startup then
    vim.schedule(start_buffer)
    return
  end

  start_buffer()
end

function M.setup(opts)
  options = merged_opts(options, opts)
  if type(lsp.set_startup_ready_callback) == "function" then
    lsp.set_startup_ready_callback(function(bufnr, payload)
      record_startup_unlock(bufnr, type(payload) == "table" and payload.source or "LspBootstrap", {
        post_lsp_bootstrap_unlock_ms = 0,
      })
    end)
  end
  if type(blink.ensure_integration) == "function" then
    blink.ensure_integration()
  end

  local group = vim.api.nvim_create_augroup("ArkNvim", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = options.filetypes,
    callback = function(args)
      start_managed_buffer(args.buf)
    end,
    desc = "Start ark.nvim pane and LSP for R-family buffers",
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    pattern = "*",
    callback = function(args)
      if not is_ark_buffer(args.buf) then
        return
      end
      vim.schedule(function()
        if type(blink.ensure_integration) == "function" then
          blink.ensure_integration()
        end
      end)
    end,
    desc = "Apply Ark Blink runtime patches after Blink initialization",
  })

  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    pattern = "*",
    callback = function(args)
      if not is_ark_buffer(args.buf) then
        return
      end
      if not startup_unlocked(args.buf) then
        return
      end
      blink.handle_insert_char_pre(args.buf)
    end,
    desc = "Track opening-pair insertions for Ark completion recovery",
  })

  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      mark_startup_safe_state(vim.api.nvim_get_current_buf())
    end,
    desc = "Record the first post-startup SafeState for the current Ark buffer",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      session_backend.stop(options)
    end,
    desc = "Stop the managed ark.nvim session on exit",
  })

  did_setup = true

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype) then
      start_managed_buffer(bufnr)
    end
  end

  vim.api.nvim_create_user_command("ArkBuildLsp", function()
    local ok, err = dev.build_detached_lsp({
      show_output = true,
    })
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end, { desc = "Rebuild the detached ark-lsp binary used by ark.nvim" })

  vim.api.nvim_create_user_command("ArkBuildBridge", function()
    local runtime_config, config_err = session_backend.runtime_config(options)
    if type(runtime_config) ~= "table" then
      notify(config_err, vim.log.levels.ERROR)
      return
    end

    local ok, err = bridge.build_session_runtime(runtime_config, {})
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end, { desc = "Rebuild the pane-side arkbridge runtime used by ark.nvim" })

  return options
end

function M.options()
  ensure_setup()
  return options
end

function M.pane_command()
  ensure_setup()
  return session_backend.pane_command(options)
end

local function prewarm_current_buffer_lsp()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_ark_buffer(bufnr) then
    return nil
  end

  -- Command-driven integrations often call `start_pane()` and `start_lsp()`
  -- back-to-back. Prewarm the detached client here so those phases do not
  -- serialize on the pane path.
  if type(lsp.prewarm) == "function" then
    return lsp.prewarm(options, bufnr)
  end

  return lsp.start_async(options, bufnr)
end

function M.start_pane()
  ensure_setup()
  prewarm_current_buffer_lsp()
  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end
  local pane_id, err = session_backend.start(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  lsp.sync_sessions(options)
  return pane_id
end

function M.new_tab()
  ensure_setup()
  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end
  local pane_id, err = session_backend.tab_new(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.next_tab()
  ensure_setup()
  local pane_id, err = session_backend.tab_next(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.prev_tab()
  ensure_setup()
  local pane_id, err = session_backend.tab_prev(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.go_tab(index)
  ensure_setup()
  local pane_id, err = session_backend.tab_go(index, options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.close_tab()
  ensure_setup()
  local pane_id, err = session_backend.tab_close(options)
  if err then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.list_tabs()
  ensure_setup()
  return session_backend.tab_list(options)
end

function M.tab_state()
  ensure_setup()
  return session_backend.tab_state(options)
end

function M.tab_badge()
  ensure_setup()
  return session_backend.tab_badge(options)
end

function M.restart_pane()
  ensure_setup()
  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end
  local pane_id, err = session_backend.restart(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.stop_pane()
  ensure_setup()
  session_backend.stop(options)
  sync_sessions_soon()
end

function M.start_lsp(bufnr)
  ensure_setup()
  return lsp.start(options, resolve_bufnr(bufnr))
end

function M.snippets(bufnr)
  ensure_setup()
  return snippets.open({
    bufnr = resolve_bufnr(bufnr),
    filetypes = options.filetypes,
    notify = notify,
  })
end

local function show_help_page(bufnr, topic)
  bufnr = resolve_bufnr(bufnr)

  if not is_ark_buffer(bufnr) then
    local err = "ark.nvim help requires an R-family buffer"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  lsp.start(options, bufnr)

  if type(topic) ~= "string" or topic == "" then
    local topic_err
    topic, topic_err = lsp.help_topic(options, bufnr)
    if not topic then
      notify(topic_err or "no help topic found", vim.log.levels.WARN)
      return nil, topic_err
    end
  end

  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    notify(bridge_err, vim.log.levels.ERROR)
    return nil, bridge_err
  end

  local _, pane_err = session_backend.start(options)
  if pane_err then
    notify(pane_err, vim.log.levels.ERROR)
    return nil, pane_err
  end

  lsp.sync_sessions(options, bufnr)

  if not wait_for_help_runtime(bufnr) then
    local err = "ark.nvim help bridge is not ready"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local page, page_err = lsp.help_text(options, bufnr, topic)
  if not page then
    notify(page_err or "no help text found", vim.log.levels.WARN)
    return nil, page_err
  end

  open_readonly_float(page.text, {
    references = page.references,
    source_bufnr = bufnr,
    on_follow = function(target)
      show_help_page(bufnr, target)
    end,
  })

  return topic, nil
end

function M.help_pane(bufnr)
  ensure_setup()
  bufnr = resolve_bufnr(bufnr)

  if not is_ark_buffer(bufnr) then
    local err = "ark.nvim help requires an R-family buffer"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  lsp.start(options, bufnr)

  local topic, topic_err = lsp.help_topic(options, bufnr)
  if not topic then
    notify(topic_err or "no help topic found", vim.log.levels.WARN)
    return nil, topic_err
  end

  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    notify(bridge_err, vim.log.levels.ERROR)
    return nil, bridge_err
  end

  local pane_id, pane_err = session_backend.start(options)
  if not pane_id then
    notify(pane_err, vim.log.levels.ERROR)
    return nil, pane_err
  end

  lsp.sync_sessions(options)

  local runtime_config = session_backend.runtime_config(options) or {}
  local repl_ready = vim.wait(tonumber(runtime_config.bridge_wait_ms or 5000) or 5000, function()
    local status = session_backend.status(options)
    return type(status) == "table" and status.repl_ready == true
  end, 100, false)
  if not repl_ready then
    local err = "managed R repl is not ready for help"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local ok, send_err = session_backend.send_text(options, help_expression(topic))
  if not ok then
    notify(send_err, vim.log.levels.ERROR)
    return nil, send_err
  end

  return topic, nil
end

function M.help(bufnr)
  ensure_setup()
  return show_help_page(bufnr, nil)
end

function M.view(expr, bufnr)
  ensure_setup()
  bufnr = resolve_bufnr(bufnr)

  if type(expr) ~= "string" or expr == "" then
    expr = vim.fn.expand("<cword>")
  end
  if type(expr) ~= "string" or expr == "" then
    local err = "no ArkView expression found"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local ok, runtime_err = ensure_runtime_ready(bufnr, "ark.nvim data explorer")
  if not ok then
    notify(runtime_err, vim.log.levels.WARN)
    return nil, runtime_err
  end

  local opened, open_err = view.open({
    expr = expr,
    source_bufnr = bufnr,
    options = options,
    lsp = lsp,
    notify = notify,
  })
  if not opened then
    notify(open_err or "failed to open ArkView", vim.log.levels.WARN)
    return nil, open_err
  end

  return opened
end

function M.view_refresh()
  ensure_setup()
  return view.refresh()
end

function M.view_close()
  ensure_setup()
  return view.close()
end

function M.refresh(bufnr)
  ensure_setup()

  if options.auto_start_pane then
    local bridge_ok = ensure_bridge_runtime({})
    if bridge_ok then
      local _, pane_err = session_backend.start(options)
      if pane_err then
        notify(pane_err, vim.log.levels.WARN)
      end
    end
  end

  return lsp.refresh(options, resolve_bufnr(bufnr))
end

function M.lsp_config(bufnr)
  ensure_setup()
  return lsp.config(options, resolve_bufnr(bufnr))
end

function M.build_lsp()
  ensure_setup()
  return dev.build_detached_lsp()
end

function M.build_bridge()
  ensure_setup()
  local runtime_config, config_err = session_backend.runtime_config(options)
  if type(runtime_config) ~= "table" then
    return nil, config_err
  end

  return bridge.build_session_runtime(runtime_config, {})
end

function M.status(opts)
  ensure_setup()
  opts = opts or {}
  local status = session_backend.status(options)
  status.startup = startup_status(vim.api.nvim_get_current_buf())
  status.lsp_cmd = options.lsp.cmd
  local runtime_config = session_backend.runtime_config(options) or {}
  status.backend = session_backend.backend_name(options)
  status.launcher = runtime_config.launcher
  if opts.include_lsp == true then
    status.lsp_status = lsp.status(options)
    local detached_status = type(status.lsp_status) == "table" and status.lsp_status.detachedSessionStatus or nil
    if type(detached_status) == "table"
      and type(detached_status.lastBootstrapSuccessMs) == "number"
      and status.startup.main_buffer_unlocked == true
      and status.startup.post_lsp_bootstrap_unlock_ms == nil
      and type(status.startup.main_buffer_unlock_at_ms) == "number"
    then
      status.startup.post_lsp_bootstrap_unlock_ms = math.max(
        0,
        status.startup.main_buffer_unlock_at_ms - detached_status.lastBootstrapSuccessMs
      )
    end
  end
  return status
end

return M
