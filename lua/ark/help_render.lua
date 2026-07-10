local M = {}

local help_float_ns = vim.api.nvim_create_namespace("ArkHelpFloat")
local help_filetype = "markdown"

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

  local label_fg = first_color(
    colors.sun,
    colors.yellow,
    colors.orange,
    colors.baby_pink,
    get_hl_color("Title", "fg"),
    normal_fg
  )
  local link_fg = first_color(
    colors.blue,
    colors.cyan,
    colors.teal,
    colors.nord_blue,
    get_hl_color("Underlined", "fg"),
    get_hl_color("DiagnosticInfo", "fg"),
    get_hl_color("Identifier", "fg"),
    "#61afef"
  )

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
    label_fg = label_fg,
    link_fg = link_fg,
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
    fg = palette.link_fg,
    bold = true,
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

local function add_line_highlight_range(buf, start_line, end_line, group, priority)
  if not start_line or not end_line or start_line > end_line then
    return
  end

  for line_index = start_line, end_line do
    add_line_highlight(buf, line_index - 1, group, priority)
  end
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

local function build_help_reference_matches(lines, references, code_lines)
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
    if code_lines and code_lines[line_index] then
      goto next_line
    end

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

    ::next_line::
  end

  return matches
end

local function help_code_lines(rendered)
  local code_lines = {}
  for _, block in ipairs((rendered or {}).code_blocks or {}) do
    for line_index = block.fence_start, block.fence_end do
      code_lines[line_index] = true
    end
  end
  return code_lines
end

local function help_reference_matches(rendered, references)
  rendered = rendered or {}
  local matches = build_help_reference_matches(rendered.lines or {}, references or {}, help_code_lines(rendered))
  for _, entry in ipairs(rendered.toc_entries or {}) do
    matches[#matches + 1] = entry
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
    toc_entries = {},
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
    return rendered
  end

  local rendered_sections = {}
  local title_line = nil
  for index, line in ipairs(rendered.lines) do
    if title_line == nil and line ~= "" then
      title_line = index
    end

    local header = help_section_name(line)
    if header then
      rendered_sections[#rendered_sections + 1] = {
        name = header,
        line = index,
      }
    end
  end

  if #rendered_sections >= 2 then
    local insert_after = title_line or 0
    if insert_after > 0 and rendered.lines[insert_after + 1] == "" then
      insert_after = insert_after + 1
    end

    local toc_lines = { "Contents:", "" }
    for _, section in ipairs(rendered_sections) do
      toc_lines[#toc_lines + 1] = "  - " .. section.name
    end
    toc_lines[#toc_lines + 1] = ""

    local next_lines = {}
    for index = 1, insert_after do
      next_lines[#next_lines + 1] = rendered.lines[index]
    end
    for _, line in ipairs(toc_lines) do
      next_lines[#next_lines + 1] = line
    end
    for index = insert_after + 1, #rendered.lines do
      next_lines[#next_lines + 1] = rendered.lines[index]
    end
    rendered.lines = next_lines

    local shift = #toc_lines
    local function shift_line(line)
      if line > insert_after then
        return line + shift
      end
      return line
    end

    for _, block in ipairs(rendered.code_blocks) do
      block.header_line = shift_line(block.header_line)
      block.fence_start = shift_line(block.fence_start)
      block.body_start = shift_line(block.body_start)
      block.body_end = shift_line(block.body_end)
      block.fence_end = shift_line(block.fence_end)
    end

    for index, section in ipairs(rendered_sections) do
      local entry_line = insert_after + 2 + index
      rendered.toc_entries[#rendered.toc_entries + 1] = {
        line = entry_line,
        start_col = 4,
        end_col = 4 + #section.name,
        label = section.name,
        section_line = shift_line(section.line),
      }
    end
  end

  return rendered
end

local function help_popup_payload(text, references, topic)
  local rendered = render_help_display(split_lines(text))
  return {
    topic = topic,
    title = topic and ("ArkHelp: " .. topic) or "ArkHelp",
    lines = rendered.lines,
    references = help_reference_matches(rendered, references),
  }
end

local function start_help_markdown_parser(buf)
  return pcall(vim.treesitter.start, buf, "markdown")
end

local function ensure_markdown_fenced_r_syntax()
  local languages = vim.g.markdown_fenced_languages
  if type(languages) ~= "table" then
    languages = {}
  else
    languages = vim.deepcopy(languages)
  end

  for _, language in ipairs(languages) do
    if language == "r" or language == "r=R" then
      vim.g.markdown_fenced_languages = languages
      return
    end
  end

  languages[#languages + 1] = "r"
  vim.g.markdown_fenced_languages = languages
end

local function start_help_markdown_syntax(buf)
  ensure_markdown_fenced_r_syntax()
  vim.api.nvim_buf_call(buf, function()
    vim.bo[buf].syntax = "markdown"
    pcall(vim.cmd, "runtime! syntax/markdown.vim")
    pcall(vim.cmd, "syntax sync fromstart")
  end)
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
        add_line_highlight(buf, block.fence_start - 1, "ArkHelpCodeFence", 120)
        if block.body_start <= block.body_end then
          add_line_highlight_range(buf, block.body_start, block.body_end, "ArkHelpUsageBody", 105)
        end
        add_line_highlight(buf, block.fence_end - 1, "ArkHelpCodeFence", 120)
      else
        add_line_highlight_range(buf, body_start, body_end, "ArkHelpUsageBody", 105)
      end
    else
      add_line_highlight(buf, section.line - 1, "ArkHelpSectionHeader", 200)
    end
  end

  local matches = help_reference_matches(rendered, references)
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
  local treesitter_started = start_help_markdown_parser(buf)
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
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(buf) then
      start_help_markdown_syntax(buf)
    end
  end, 20)

  local close = function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local current_topic = type(opts.topic) == "string" and opts.topic or nil
  local back_stack = {}
  local forward_stack = {}

  local function notify_help(message)
    vim.notify(tostring(message), vim.log.levels.WARN, { title = "ark.nvim" })
  end

  local function request_page(target)
    if type(opts.on_request_page) ~= "function" then
      return nil, "ArkHelp history navigation is unavailable"
    end

    return opts.on_request_page(target)
  end

  local function set_page(page, target)
    if type(page) ~= "table" or type(page.text) ~= "string" then
      return nil, "invalid ArkHelp page response"
    end

    local next_rendered = render_help_display(split_lines(page.text))
    local next_lines = next_rendered.lines
    if #next_lines == 0 then
      next_lines = { "" }
      next_rendered.lines = next_lines
    end

    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, next_lines)
    vim.bo[buf].filetype = help_filetype
    local treesitter_started = start_help_markdown_parser(buf)
    vim.b[buf].ark_help_treesitter = treesitter_started
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    apply_help_highlights(buf, next_rendered, page.references or {})
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(buf) then
        start_help_markdown_syntax(buf)
      end
    end, 20)

    current_topic = type(page.topic) == "string" and page.topic ~= "" and page.topic or target
    vim.b[buf].ark_help_topic = current_topic
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    return true, nil
  end

  local function follow_target(target)
    if type(target) ~= "string" or target == "" then
      return
    end

    local page, err = request_page(target)
    if not page then
      notify_help(err or "failed to follow ArkHelp link")
      return
    end

    local previous = current_topic
    local ok, set_err = set_page(page, target)
    if not ok then
      notify_help(set_err or "failed to render ArkHelp link")
      return
    end

    if type(previous) == "string" and previous ~= "" and previous ~= current_topic then
      back_stack[#back_stack + 1] = previous
      forward_stack = {}
    end
  end

  local function history_back()
    local target = back_stack[#back_stack]
    if type(target) ~= "string" or target == "" then
      return
    end

    local page, err = request_page(target)
    if not page then
      notify_help(err or "failed to open previous ArkHelp page")
      return
    end

    local previous = current_topic
    local ok, set_err = set_page(page, target)
    if not ok then
      notify_help(set_err or "failed to render previous ArkHelp page")
      return
    end

    back_stack[#back_stack] = nil
    if type(previous) == "string" and previous ~= "" and previous ~= current_topic then
      forward_stack[#forward_stack + 1] = previous
    end
  end

  local function history_forward()
    local target = forward_stack[#forward_stack]
    if type(target) ~= "string" or target == "" then
      return
    end

    local page, err = request_page(target)
    if not page then
      notify_help(err or "failed to open next ArkHelp page")
      return
    end

    local previous = current_topic
    local ok, set_err = set_page(page, target)
    if not ok then
      notify_help(set_err or "failed to render next ArkHelp page")
      return
    end

    forward_stack[#forward_stack] = nil
    if type(previous) == "string" and previous ~= "" and previous ~= current_topic then
      back_stack[#back_stack + 1] = previous
    end
  end

  vim.b[buf].ark_help_source_bufnr = opts.source_bufnr
  vim.b[buf].ark_help_buffer = true
  vim.b[buf].ark_help_topic = current_topic

  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", function()
    local match = reference_under_cursor(buf)
    if not match then
      return
    end

    if type(match.section_line) == "number" and match.section_line > 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { match.section_line, 0 })
      return
    end

    follow_target(match.target)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "H", history_back, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "L", history_forward, { buffer = buf, nowait = true, silent = true })

  return buf, win
end

local function normalize_help_display(value)
  if type(value) ~= "string" or value == "" then
    return "auto"
  end

  value = value:lower():gsub("-", "_")
  if value == "float" or value == "nvim" or value == "nvim_float" then
    return "float"
  end
  if value == "popup" or value == "tmux" or value == "tmux_popup" then
    return "tmux_popup"
  end
  if value == "auto" then
    return "auto"
  end

  return "auto"
end

local function normalize_view_display(value)
  if type(value) ~= "string" or value == "" then
    return "auto"
  end

  value = value:lower():gsub("-", "_")
  if value == "tab" or value == "nvim" or value == "nvim_tab" then
    return "tab"
  end
  if value == "popup" or value == "tmux" or value == "tmux_popup" then
    return "tmux_popup"
  end
  if value == "auto" then
    return "auto"
  end

  return "auto"
end

M.expression = help_expression
M.help_popup_payload = help_popup_payload
M.normalize_help_display = normalize_help_display
M.normalize_view_display = normalize_view_display
M.open_readonly_float = open_readonly_float
M.render = render_help_display
M.r_string_literal = r_string_literal

return M
