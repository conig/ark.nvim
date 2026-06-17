local M = {}

local state = _G.__ark_theme_state
if type(state) ~= "table" then
  state = {}
end
_G.__ark_theme_state = state

local function color_value(value)
  if type(value) == "number" then
    return string.format("#%06x", value)
  end
  if type(value) == "string" and value:match("^#%x%x%x%x%x%x$") then
    return value
  end
  return nil
end

local function get_hl(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if not ok or type(hl) ~= "table" then
    return {}
  end
  return hl
end

local function hl_color(name, key)
  return color_value(get_hl(name)[key])
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

local function hex_to_rgb(value)
  value = color_value(value)
  if not value then
    return nil
  end

  return tonumber(value:sub(2, 3), 16), tonumber(value:sub(4, 5), 16), tonumber(value:sub(6, 7), 16)
end

local function blend_color(foreground, background, alpha)
  local fr, fg, fb = hex_to_rgb(foreground)
  local br, bg, bb = hex_to_rgb(background)
  if not fr or not br then
    return nil
  end

  alpha = math.max(0, math.min(1, tonumber(alpha) or 0))
  return string.format(
    "#%02x%02x%02x",
    math.floor((fr * alpha) + (br * (1 - alpha)) + 0.5),
    math.floor((fg * alpha) + (bg * (1 - alpha)) + 0.5),
    math.floor((fb * alpha) + (bb * (1 - alpha)) + 0.5)
  )
end

local function luminance(value)
  local red, green, blue = hex_to_rgb(value)
  if not red then
    return nil
  end
  return (red * 0.299) + (green * 0.587) + (blue * 0.114)
end

local function color_distance(lhs, rhs)
  local lr, lg, lb = hex_to_rgb(lhs)
  local rr, rg, rb = hex_to_rgb(rhs)
  if not lr or not rr then
    return 0
  end

  return math.sqrt(((lr - rr) ^ 2) + ((lg - rg) ^ 2) + ((lb - rb) ^ 2))
end

local function darker_surface(normal_bg, base_30)
  local base46_bg = first_color(
    base_30.darker_black,
    base_30.black2,
    base_30.black,
    base_30.one_bg
  )
  if base46_bg and (not normal_bg or base46_bg ~= normal_bg) then
    return base46_bg
  end

  local bg = first_color(normal_bg, "#1f1f1f")
  local amount = (luminance(bg) or 0) >= 128 and 0.18 or 0.12
  return blend_color("#000000", bg, amount) or bg
end

local function float_surface(normal_bg, repl_bg, base_30)
  for index = 1, 5 do
    local candidate = ({
      first_color(base_30.one_bg2),
      first_color(base_30.one_bg),
      first_color(base_30.black2),
      hl_color("NormalFloat", "bg"),
      normal_bg,
    })[index]
    if candidate and color_distance(candidate, repl_bg) >= 18 then
      return candidate
    end
  end

  local bg = first_color(repl_bg, normal_bg, "#1f1f1f")
  local target = (luminance(bg) or 0) >= 128 and "#000000" or "#ffffff"
  return blend_color(target, bg, 0.12) or bg
end

local function base46_tables()
  local ok, base46 = pcall(require, "base46")
  if not ok or type(base46) ~= "table" or type(base46.get_theme_tb) ~= "function" then
    return {}, {}
  end

  return base46.get_theme_tb("base_30") or {}, base46.get_theme_tb("base_16") or {}
end

local function terminal_color(index)
  return color_value(vim.g["terminal_color_" .. tostring(index)])
end

local function base46_terminal_colors(base_30, base_16)
  return {
    first_color(base_16.base00, base_30.black, "#2e3436"),
    first_color(base_16.base08, base_30.red, "#cc0000"),
    first_color(base_16.base0B, base_30.green, "#4e9a06"),
    first_color(base_16.base0A, base_30.yellow, "#c4a000"),
    first_color(base_16.base0D, base_30.blue, "#3465a4"),
    first_color(base_16.base0E, base_30.purple, "#75507b"),
    first_color(base_16.base0C, base_30.cyan, "#06989a"),
    first_color(base_16.base05, base_30.white, "#d3d7cf"),
    first_color(base_30.grey, base_16.base03, "#555753"),
    first_color(base_30.baby_pink, base_30.blood, base_16.base08, base_30.red, "#ef2929"),
    first_color(base_30.vibrant_green, base_16.base0B, base_30.green, "#8ae234"),
    first_color(base_30.sun, base_30.unique_gold, base_16.base0A, base_30.yellow, "#fce94f"),
    first_color(base_30.folder_bg, base_16.base0D, base_30.blue, "#729fcf"),
    first_color(base_30.dark_purple, base_16.base0E, base_30.purple, "#ad7fa8"),
    first_color(base_30.teal, base_16.base0C, base_30.cyan, "#34e2e2"),
    first_color(base_30.lighter_white, base_30.pure_white, base_16.base07, base_30.white, "#eeeeec"),
  }
end

local syntax_highlight_names = {
  "Comment",
  "Constant",
  "String",
  "Character",
  "Number",
  "Boolean",
  "Float",
  "Identifier",
  "Function",
  "Statement",
  "Conditional",
  "Repeat",
  "Label",
  "Operator",
  "Keyword",
  "Exception",
  "PreProc",
  "Include",
  "Define",
  "Macro",
  "PreCondit",
  "Type",
  "StorageClass",
  "Structure",
  "Typedef",
  "Special",
  "SpecialChar",
  "Tag",
  "Delimiter",
  "SpecialComment",
  "Debug",
  "Underlined",
  "Error",
  "Todo",
  "NormalFloat",
  "FloatBorder",
  "Pmenu",
  "PmenuSel",
  "BlinkCmpDoc",
  "BlinkCmpDocBorder",
  "BlinkCmpDocCursorLine",
  "BlinkCmpGhostText",
  "BlinkCmpKind",
  "BlinkCmpKindClass",
  "BlinkCmpKindColor",
  "BlinkCmpKindConstant",
  "BlinkCmpKindConstructor",
  "BlinkCmpKindEnum",
  "BlinkCmpKindEnumMember",
  "BlinkCmpKindEvent",
  "BlinkCmpKindField",
  "BlinkCmpKindFile",
  "BlinkCmpKindFolder",
  "BlinkCmpKindFunction",
  "BlinkCmpKindInterface",
  "BlinkCmpKindKeyword",
  "BlinkCmpKindMethod",
  "BlinkCmpKindModule",
  "BlinkCmpKindOperator",
  "BlinkCmpKindProperty",
  "BlinkCmpKindReference",
  "BlinkCmpKindSnippet",
  "BlinkCmpKindStruct",
  "BlinkCmpKindText",
  "BlinkCmpKindTypeParameter",
  "BlinkCmpKindUnit",
  "BlinkCmpKindValue",
  "BlinkCmpKindVariable",
  "BlinkCmpLabel",
  "BlinkCmpLabelDeprecated",
  "BlinkCmpLabelDescription",
  "BlinkCmpLabelDetail",
  "BlinkCmpLabelMatch",
  "BlinkCmpMenu",
  "BlinkCmpMenuBorder",
  "BlinkCmpMenuSelection",
  "BlinkCmpScrollBarGutter",
  "BlinkCmpScrollBarThumb",
  "BlinkCmpSignatureHelp",
  "BlinkCmpSignatureHelpActiveParameter",
  "BlinkCmpSignatureHelpBorder",
  "BlinkCmpSource",
  "rAssign",
  "rBoolean",
  "rComment",
  "rConditional",
  "rConstant",
  "rDelimiter",
  "rError",
  "rFloat",
  "rFunction",
  "rNumber",
  "rOpError",
  "rOperator",
  "rRepeat",
  "rSpecial",
  "rString",
}

local function capture_highlight(name)
  local hl = get_hl(name)
  if not next(hl) then
    return nil
  end

  local spec = {}
  if color_value(hl.fg) then
    spec.fg = color_value(hl.fg)
  end
  if color_value(hl.bg) then
    spec.bg = color_value(hl.bg)
  end
  if color_value(hl.sp) then
    spec.sp = color_value(hl.sp)
  end
  for _, key in ipairs({ "bold", "italic", "underline", "undercurl", "strikethrough", "reverse" }) do
    if hl[key] ~= nil then
      spec[key] = hl[key] == true
    end
  end

  if not next(spec) then
    return nil
  end
  return spec
end

local function capture_syntax_highlights()
  local out = {}
  for _, name in ipairs(syntax_highlight_names) do
    local spec = capture_highlight(name)
    if spec then
      out[name] = spec
    end
  end
  return out
end

local repl_function_groups = {
  "Function",
  "rFunction",
  "@function",
  "@function.call",
  "@function.builtin",
  "@function.method",
  "@function.method.call",
}

function M.snapshot()
  local base_30, base_16 = base46_tables()
  local base46_ansi = base46_terminal_colors(base_30, base_16)
  local ansi = {}
  for index = 0, 15 do
    ansi[index + 1] = first_color(terminal_color(index), base46_ansi[index + 1])
  end

  local normal_bg = first_color(hl_color("Normal", "bg"), base_30.black, base_16.base00)
  local normal_fg = first_color(hl_color("Normal", "fg"), base_30.white, base_16.base05)
  local repl_bg = darker_surface(normal_bg, base_30)
  local signature_bg = float_surface(normal_bg, repl_bg, base_30)
  local float_border_fg = first_color(base_30.grey_fg, hl_color("FloatBorder", "fg"), normal_fg)
  local selection_bg = first_color(hl_color("PmenuSel", "bg"), base_30.one_bg3, blend_color("#ffffff", signature_bg, 0.14))
  local match_fg = first_color(base_30.orange, base_30.yellow, hl_color("Special", "fg"), normal_fg)

  return {
    version = 1,
    normal = {
      fg = normal_fg,
      bg = repl_bg,
      source_bg = normal_bg,
    },
    console = {
      normal = {
        fg = normal_fg,
        bg = repl_bg,
      },
      prompt = {
        fg = first_color(base_30.green, base_30.unique_gold, hl_color("Question", "fg"), base_16.base0B, normal_fg),
        bg = repl_bg,
        bold = get_hl("Question").bold == true,
      },
      output = {
        fg = normal_fg,
        bg = repl_bg,
      },
      output_value = {
        fg = first_color(base_30.lighter_white, normal_fg),
        bg = repl_bg,
      },
      output_message = {
        fg = first_color(base_30.cyan, hl_color("DiagnosticInfo", "fg"), normal_fg),
        bg = repl_bg,
      },
      output_warning = {
        fg = first_color(base_30.yellow, base_30.sun, hl_color("DiagnosticWarn", "fg"), normal_fg),
        bg = repl_bg,
        bold = true,
      },
      output_error = {
        fg = first_color(base_30.baby_pink, base_30.blood, base_30.red, hl_color("DiagnosticError", "fg"), normal_fg),
        bg = repl_bg,
        bold = true,
      },
      output_prefix = {
        fg = first_color(hl_color("Comment", "fg"), base_30.grey_fg, base_16.base03, normal_fg),
        bg = repl_bg,
        italic = get_hl("Comment").italic == true,
      },
      signature = {
        fg = first_color(hl_color("NormalFloat", "fg"), normal_fg),
        bg = signature_bg,
      },
      signature_border = {
        fg = float_border_fg,
        bg = signature_bg,
      },
      blink = {
        menu = { fg = normal_fg, bg = signature_bg },
        menu_border = { fg = float_border_fg, bg = signature_bg },
        menu_selection = { fg = normal_fg, bg = selection_bg },
        doc = { fg = normal_fg, bg = signature_bg },
        doc_border = { fg = float_border_fg, bg = signature_bg },
        label = { fg = normal_fg, bg = signature_bg },
        label_match = { fg = match_fg, bg = signature_bg, bold = true },
        label_detail = { fg = first_color(hl_color("Comment", "fg"), base_30.grey_fg, normal_fg), bg = signature_bg },
        source = { fg = first_color(hl_color("Comment", "fg"), base_30.grey_fg, normal_fg), bg = signature_bg },
        ghost = { fg = first_color(hl_color("Comment", "fg"), base_30.grey_fg, normal_fg), bg = repl_bg },
        signature = { fg = normal_fg, bg = signature_bg },
        signature_border = { fg = float_border_fg, bg = signature_bg },
        signature_active_parameter = { fg = match_fg, bg = signature_bg, bold = true },
      },
      syntax = {
        function_call = {
          fg = first_color(base_30.orange, base_16.base09, hl_color("@function.call", "fg"), hl_color("Function", "fg"), normal_fg),
        },
      },
    },
    terminal = {
      colors = ansi,
    },
    highlights = capture_syntax_highlights(),
  }
end

local function set_hl(name, spec)
  if type(spec) ~= "table" then
    return
  end

  local opts = {}
  if color_value(spec.fg) then
    opts.fg = spec.fg
  end
  if color_value(spec.bg) then
    opts.bg = spec.bg
  end
  if spec.bold ~= nil then
    opts.bold = spec.bold == true
  end
  if spec.italic ~= nil then
    opts.italic = spec.italic == true
  end
  if spec.underline ~= nil then
    opts.underline = spec.underline == true
  end
  if spec.undercurl ~= nil then
    opts.undercurl = spec.undercurl == true
  end
  if spec.strikethrough ~= nil then
    opts.strikethrough = spec.strikethrough == true
  end
  if spec.reverse ~= nil then
    opts.reverse = spec.reverse == true
  end
  if color_value(spec.sp) then
    opts.sp = spec.sp
  end

  if next(opts) then
    pcall(vim.api.nvim_set_hl, 0, name, opts)
  end
end

function M.apply_syntax_palette(palette)
  local highlights = type(palette) == "table" and type(palette.highlights) == "table" and palette.highlights or nil
  if not highlights then
    return false
  end

  for name, spec in pairs(highlights) do
    if type(name) == "string" and type(spec) == "table" then
      set_hl(name, spec)
    end
  end

  local syntax = type(palette.console) == "table" and type(palette.console.syntax) == "table" and palette.console.syntax or nil
  local function_call = type(syntax) == "table" and syntax.function_call or nil
  if type(function_call) == "table" then
    for _, name in ipairs(repl_function_groups) do
      set_hl(name, function_call)
    end
  end

  return true
end

function M.apply_blink_palette(palette)
  local blink = type(palette) == "table"
      and type(palette.console) == "table"
      and type(palette.console.blink) == "table"
      and palette.console.blink
    or nil
  if not blink then
    return false
  end

  set_hl("BlinkCmpMenu", blink.menu)
  set_hl("BlinkCmpMenuBorder", blink.menu_border)
  set_hl("BlinkCmpMenuSelection", blink.menu_selection)
  set_hl("BlinkCmpDoc", blink.doc)
  set_hl("BlinkCmpDocBorder", blink.doc_border)
  set_hl("BlinkCmpDocCursorLine", blink.menu_selection)
  set_hl("BlinkCmpLabel", blink.label)
  set_hl("BlinkCmpLabelMatch", blink.label_match)
  set_hl("BlinkCmpLabelDetail", blink.label_detail)
  set_hl("BlinkCmpLabelDescription", blink.label_detail)
  set_hl("BlinkCmpSource", blink.source)
  set_hl("BlinkCmpGhostText", blink.ghost)
  set_hl("BlinkCmpSignatureHelp", blink.signature)
  set_hl("BlinkCmpSignatureHelpBorder", blink.signature_border)
  set_hl("BlinkCmpSignatureHelpActiveParameter", blink.signature_active_parameter)
  return true
end

function M.apply_float_palette(palette)
  if type(palette) ~= "table" or type(palette.console) ~= "table" then
    return false
  end

  set_hl("ArkSignatureHelpNormal", palette.console.signature)
  set_hl("ArkSignatureHelpBorder", palette.console.signature_border)
  return true
end

function M.apply_console_palette(palette)
  if type(palette) ~= "table" or type(palette.console) ~= "table" then
    return false
  end

  set_hl("ArkConsoleNormal", palette.console.normal or palette.normal)
  set_hl("ArkConsolePrompt", palette.console.prompt)
  set_hl("ArkConsoleOutput", palette.console.output)
  set_hl("ArkConsoleOutputValue", palette.console.output_value or palette.console.output)
  set_hl("ArkConsoleOutputMessage", palette.console.output_message or palette.console.output)
  set_hl("ArkConsoleOutputWarning", palette.console.output_warning or palette.console.output)
  set_hl("ArkConsoleOutputError", palette.console.output_error or palette.console.output)
  set_hl("ArkConsoleOutputPrefix", palette.console.output_prefix)
  M.apply_float_palette(palette)
  return true
end

function M.apply_terminal_palette(palette)
  local colors = type(palette) == "table"
      and type(palette.terminal) == "table"
      and type(palette.terminal.colors) == "table"
      and palette.terminal.colors
    or nil
  if not colors then
    return false
  end

  for index = 0, 15 do
    local value = color_value(colors[index + 1])
    if value then
      vim.g["terminal_color_" .. tostring(index)] = value
    end
  end
  return true
end

function M.read(path)
  if type(path) ~= "string" or path == "" or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function default_handoff_file()
  local state_dir = vim.fn.stdpath("state")
  if type(state_dir) ~= "string" or state_dir == "" then
    state_dir = "/tmp"
  end
  return vim.fs.normalize(state_dir .. "/ark-repl-theme/theme-" .. tostring(vim.fn.getpid()) .. ".json")
end

function M.write_snapshot_file(path)
  path = type(path) == "string" and path ~= "" and path or default_handoff_file()
  local dir = vim.fs.dirname(path)
  if type(dir) == "string" and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end

  local ok = pcall(vim.fn.writefile, { vim.json.encode(M.snapshot()) }, path)
  if not ok then
    return nil
  end
  return vim.fs.normalize(path)
end

function M.prepare_handoff()
  local path = state.handoff_file
  if type(path) ~= "string" or path == "" then
    path = default_handoff_file()
    state.handoff_file = path
  end

  path = M.write_snapshot_file(path)
  if not path then
    return nil
  end

  if state.parent_autocmd ~= true then
    local group = vim.api.nvim_create_augroup("ArkReplThemeHandoff", { clear = true })
    local function refresh_handoff()
      vim.schedule(function()
        M.write_snapshot_file(state.handoff_file)
      end)
    end
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = refresh_handoff,
      desc = "Refresh Ark REPL theme handoff",
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "NvThemeReload",
      callback = refresh_handoff,
      desc = "Refresh Ark REPL theme handoff after Base46 reload",
    })
    state.parent_autocmd = true
  end

  return path
end

function M.palette_from_env()
  return M.read(vim.env.ARK_NVIM_REPL_THEME_FILE)
end

function M.apply_from_env()
  local palette = M.palette_from_env()
  if not palette then
    return false
  end

  M.apply_terminal_palette(palette)
  M.apply_blink_palette(palette)
  M.apply_syntax_palette(palette)
  M.apply_console_palette(palette)
  return true
end

local function file_signature(path)
  local stat = type(path) == "string" and vim.uv.fs_stat(path) or nil
  if type(stat) ~= "table" then
    return nil
  end

  local mtime = stat.mtime
  local sec = type(mtime) == "table" and mtime.sec or 0
  local nsec = type(mtime) == "table" and mtime.nsec or 0
  return table.concat({ tostring(stat.size or 0), tostring(sec), tostring(nsec) }, ":")
end

function M.enable_receiver_updates()
  local path = vim.env.ARK_NVIM_REPL_THEME_FILE
  if type(path) ~= "string" or path == "" then
    return false
  end

  local function apply_if_changed(force)
    local signature = file_signature(path)
    if not signature then
      return
    end
    if force or state.receiver_signature ~= signature then
      state.receiver_signature = signature
      M.apply_from_env()
    end
  end

  apply_if_changed(true)

  if state.receiver_autocmd ~= true then
    local group = vim.api.nvim_create_augroup("ArkReplThemeReceiver", { clear = true })
    local function refresh_receiver()
      apply_if_changed(true)
    end
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = group,
      callback = refresh_receiver,
      desc = "Apply Ark REPL theme handoff",
    })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "NvThemeReload",
      callback = refresh_receiver,
      desc = "Apply Ark REPL theme handoff after Base46 reload",
    })
    state.receiver_autocmd = true
  end

  if state.receiver_timer then
    return true
  end

  local timer = vim.uv.new_timer()
  if not timer then
    return true
  end
  timer:start(1000, 1000, vim.schedule_wrap(function()
    apply_if_changed(false)
  end))
  pcall(function()
    timer:unref()
  end)
  state.receiver_timer = timer

  return true
end

return M
