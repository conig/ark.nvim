local M = {}
local commands_registered = false
local context_patched = false
local sources_configured = false
local selection_patched = false
local trigger_patched = false
local docs_patched = false
local show_patched = false
local menu_patched = false
local signature_float_patched = false
local active_signature_help_win = nil

local ark_filetypes = { "r", "rmd", "qmd", "quarto" }

local function active_ark_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })
  return clients[1] ~= nil
end

local function in_ark_filetype(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return vim.tbl_contains(ark_filetypes, filetype)
end

local function hide_visible_blink_menu()
  local ok_blink, blink = pcall(require, "blink.cmp")
  if not ok_blink or not blink.is_visible() then
    return
  end

  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  if ok_trigger and type(trigger.hide) == "function" then
    pcall(trigger.hide)
  end

  local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
  if ok_menu and menu and type(menu.close) == "function" then
    pcall(menu.close)
    if menu.win and type(menu.win.get_buf) == "function" then
      local menu_buf = menu.win:get_buf()
      if vim.api.nvim_buf_is_valid(menu_buf) then
        local line_count = math.max(vim.api.nvim_buf_line_count(menu_buf), 1)
        local blank_lines = {}
        for i = 1, line_count do
          blank_lines[i] = ""
        end
        pcall(vim.api.nvim_set_option_value, "modifiable", true, { buf = menu_buf })
        pcall(vim.api.nvim_buf_set_lines, menu_buf, 0, -1, false, blank_lines)
        pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = menu_buf })
      end
    end
  end

  local ok_docs, docs = pcall(require, "blink.cmp.completion.windows.documentation")
  if ok_docs and docs and type(docs.close) == "function" then
    pcall(docs.close)
  end
end

local function close_blink_docs()
  local ok_docs, docs = pcall(require, "blink.cmp.completion.windows.documentation")
  if ok_docs and docs and type(docs.close) == "function" then
    pcall(docs.close)
  end
end

local function current_signature_help_win()
  if type(active_signature_help_win) ~= "number" or active_signature_help_win == 0 then
    active_signature_help_win = nil
    return nil
  end

  if not vim.api.nvim_win_is_valid(active_signature_help_win) then
    active_signature_help_win = nil
    return nil
  end

  local config = vim.api.nvim_win_get_config(active_signature_help_win)
  if type(config) ~= "table" or type(config.relative) ~= "string" or config.relative == "" then
    active_signature_help_win = nil
    return nil
  end

  return active_signature_help_win
end

local function signature_help_visible()
  return current_signature_help_win() ~= nil
end

local function blink_menu_win()
  local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
  if not ok_menu or not menu or not menu.win or type(menu.win.get_win) ~= "function" then
    return nil
  end

  local win = menu.win:get_win()
  if type(win) ~= "number" or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  return win
end

local function absolute_float_position(config)
  if type(config) ~= "table" then
    return nil
  end

  local row = tonumber(config.row)
  local col = tonumber(config.col)
  if not row or not col then
    return nil
  end

  if config.relative == "editor" then
    return {
      row = row,
      col = col,
    }
  end

  if config.relative == "win" and type(config.win) == "number" and config.win ~= 0 then
    local ok, parent_pos = pcall(vim.api.nvim_win_get_position, config.win)
    if ok and type(parent_pos) == "table" and #parent_pos >= 2 then
      return {
        row = parent_pos[1] + row,
        col = parent_pos[2] + col,
      }
    end
  end

  return nil
end

local function window_bounds(win)
  if type(win) ~= "number" or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  local config = vim.api.nvim_win_get_config(win)
  local pos = absolute_float_position(config)
  if not pos then
    return nil
  end

  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)

  return {
    top = pos.row,
    left = pos.col,
    bottom = pos.row + height,
    right = pos.col + width,
  }
end

local function windows_overlap(lhs, rhs)
  if lhs == nil or rhs == nil then
    return false
  end

  return lhs.left < rhs.right
    and rhs.left < lhs.right
    and lhs.top < rhs.bottom
    and rhs.top < lhs.bottom
end

local function position_signature_float_away_from_menu(win)
  if type(win) ~= "number" or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  local menu_win = blink_menu_win()
  if not menu_win or menu_win == win then
    return false
  end

  local menu_config = vim.api.nvim_win_get_config(menu_win)
  local menu_pos = absolute_float_position(menu_config)
  if not menu_pos then
    return false
  end

  local menu_width = vim.api.nvim_win_get_width(menu_win)
  local menu_height = vim.api.nvim_win_get_height(menu_win)
  local win_width = vim.api.nvim_win_get_width(win)
  local win_height = vim.api.nvim_win_get_height(win)
  local gap = 1
  local max_row = math.max(vim.o.lines - vim.o.cmdheight - 1, 0)
  local max_col = math.max(vim.o.columns - 1, 0)

  local candidates = {
    {
      row = menu_pos.row,
      col = menu_pos.col + menu_width + gap,
      fits = (menu_pos.col + menu_width + gap + win_width) <= max_col,
    },
    {
      row = menu_pos.row,
      col = menu_pos.col - win_width - gap,
      fits = (menu_pos.col - win_width - gap) >= 0,
    },
    {
      row = menu_pos.row + menu_height + gap,
      col = menu_pos.col,
      fits = (menu_pos.row + menu_height + gap + win_height) <= max_row,
    },
    {
      row = menu_pos.row - win_height - gap,
      col = menu_pos.col,
      fits = (menu_pos.row - win_height - gap) >= 0,
    },
  }

  local target = nil
  for _, candidate in ipairs(candidates) do
    if candidate.fits then
      target = candidate
      break
    end
  end

  if not target then
    return false
  end

  vim.api.nvim_win_set_config(win, {
    relative = "editor",
    row = math.max(0, target.row),
    col = math.max(0, target.col),
  })

  return true
end

local function resolve_signature_help_menu_collision(win)
  if type(win) ~= "number" or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local menu_win = blink_menu_win()
  if not menu_win or menu_win == win then
    return
  end

  local signature_bounds = window_bounds(win)
  local menu_bounds = window_bounds(menu_win)
  if not windows_overlap(signature_bounds, menu_bounds) then
    return
  end

  if position_signature_float_away_from_menu(win) then
    signature_bounds = window_bounds(win)
    menu_win = blink_menu_win()
    menu_bounds = window_bounds(menu_win)
    if not windows_overlap(signature_bounds, menu_bounds) then
      return
    end
  end

  -- If there isn't room for both floats, preserve the signature help.
  hide_visible_blink_menu()
end

local function ark_provider(base_provider, overrides)
  return vim.tbl_deep_extend("force", vim.deepcopy(base_provider or {}), overrides or {})
end

local function ark_auto_keyword_min_length(context)
  local trigger = type(context) == "table" and context.trigger or nil
  local initial_kind = type(trigger) == "table" and trigger.initial_kind or nil
  if initial_kind == "manual" or initial_kind == "trigger_character" then
    return 0
  end
  return 1
end

local function is_extractor_trigger(context)
  local trigger = type(context) == "table" and context.trigger or nil
  local kind = type(trigger) == "table" and trigger.kind or nil
  local character = type(trigger) == "table" and trigger.character or nil
  return kind == "trigger_character" and (character == "$" or character == "@")
end

local function line_prefix_at_cursor(context)
  local line = type(context) == "table" and context.line or nil
  local cursor = type(context) == "table" and context.cursor or nil
  local col = type(cursor) == "table" and cursor[2] or nil
  if type(line) ~= "string" or type(col) ~= "number" or col < 0 then
    return nil
  end
  return line:sub(1, col)
end

local function is_lsp_string_trigger(context)
  local trigger = type(context) == "table" and context.trigger or nil
  local kind = type(trigger) == "table" and trigger.kind or nil
  local character = type(trigger) == "table" and trigger.character or nil
  if kind ~= "trigger_character" or not (character == '"' or character == "'") then
    return false
  end

  local prefix = line_prefix_at_cursor(context)
  if type(prefix) ~= "string" then
    return false
  end

  local quote_pattern = character == '"' and '"[^"]*$' or "'[^']*$"

  return prefix:match("==%s*" .. quote_pattern) ~= nil
    or prefix:match("!=%s*" .. quote_pattern) ~= nil
    or prefix:match("^%s*library%s*%(%s*" .. quote_pattern) ~= nil
    or prefix:match("^%s*require%s*%(%s*" .. quote_pattern) ~= nil
    or prefix:match("[A-Za-z.][A-Za-z0-9._]*%s*%[%[%s*" .. quote_pattern) ~= nil
    or prefix:match("[A-Za-z.][A-Za-z0-9._]*%s*%[%s*" .. quote_pattern) ~= nil
    or prefix:match("[A-Za-z.][A-Za-z0-9._]*%s*%[%s*[^,%]]*,%s*" .. quote_pattern) ~= nil
    or prefix:match("[A-Za-z.][A-Za-z0-9._]*%s*%[%s*[^,%]]*,%s*c%s*%(%s*" .. quote_pattern) ~= nil
    or prefix:match("[,(]%s*[A-Za-z.][A-Za-z0-9._]*%s*=%s*" .. quote_pattern) ~= nil
end

local function is_lsp_subset_trigger(context)
  local trigger = type(context) == "table" and context.trigger or nil
  local kind = type(trigger) == "table" and trigger.kind or nil
  local character = type(trigger) == "table" and trigger.character or nil
  if kind ~= "trigger_character" or not (character == "[" or character == "(" or character == "," or character == " ") then
    return false
  end

  local prefix = line_prefix_at_cursor(context)
  if type(prefix) ~= "string" then
    return false
  end

  return prefix:match('[A-Za-z.][A-Za-z0-9._]*%s*%[%s*$') ~= nil
    or prefix:match('[A-Za-z.][A-Za-z0-9._]*%s*%[%[%s*$') ~= nil
    or prefix:match('[A-Za-z.][A-Za-z0-9._]*%s*%[%s*[^,%]]*,%s*%.%(%s*$') ~= nil
    or prefix:match('[A-Za-z.][A-Za-z0-9._]*%s*%[%s*[^,%]]*,%s*c%s*%(%s*$') ~= nil
    or prefix:match('[A-Za-z.][A-Za-z0-9._]*%s*%[%s*[^,%]]*,%s*%.%([^%]]*,%s*$') ~= nil
    or prefix:match('[A-Za-z.][A-Za-z0-9._]*%s*%[%s*[^,%]]*,%s*c%s*%([^%]]*,%s*$') ~= nil
end

local function ark_should_show_auto_items(context)
  local trigger = type(context) == "table" and context.trigger or nil
  local initial_kind = type(trigger) == "table" and trigger.initial_kind or nil
  if initial_kind == "manual" or initial_kind == "trigger_character" then
    return true
  end

  local line = type(context) == "table" and context.line or nil
  local cursor = type(context) == "table" and context.cursor or nil
  local col = type(cursor) == "table" and cursor[2] or nil
  if type(line) ~= "string" or type(col) ~= "number" or col < 0 then
    return true
  end

  local prefix = line:sub(1, col)
  return prefix:match("^%s*$") == nil
end

local function ark_should_show_non_lsp_items(context)
  if is_extractor_trigger(context) or is_lsp_string_trigger(context) or is_lsp_subset_trigger(context) then
    return false
  end
  return ark_should_show_auto_items(context)
end

function M.configure_blink_sources()
  if sources_configured then
    return
  end

  local ok_blink, blink = pcall(require, "blink.cmp")
  local ok_config, blink_config = pcall(require, "blink.cmp.config")
  if not ok_blink or not ok_config then
    return
  end

  local sources = blink_config.sources or {}
  local providers = sources.providers or {}
  if type(providers.lsp) ~= "table" then
    return
  end

  local has_buffer = type(providers.buffer) == "table"
  local ark_buffer_id = has_buffer and "ark_buffer" or nil

  if has_buffer and providers.ark_buffer == nil then
    blink.add_source_provider("ark_buffer", ark_provider(providers.buffer, {
      min_keyword_length = 1,
      should_show_items = ark_should_show_non_lsp_items,
    }))
  end

  if providers.ark_lsp == nil then
    blink.add_source_provider("ark_lsp", ark_provider(providers.lsp, {
      min_keyword_length = ark_auto_keyword_min_length,
      fallbacks = {},
      should_show_items = ark_should_show_auto_items,
    }))
  end

  if type(providers.path) == "table" and providers.ark_path == nil then
    blink.add_source_provider("ark_path", ark_provider(providers.path, {
      min_keyword_length = ark_auto_keyword_min_length,
      fallbacks = {},
      should_show_items = ark_should_show_non_lsp_items,
    }))
  end

  sources.per_filetype = sources.per_filetype or {}

  local ark_sources = { "ark_lsp", inherit_defaults = false }
  if providers.ark_path ~= nil or providers.path ~= nil then
    ark_sources[#ark_sources + 1] = "ark_path"
  end
  if ark_buffer_id ~= nil then
    ark_sources[#ark_sources + 1] = ark_buffer_id
  end

  for _, filetype in ipairs(ark_filetypes) do
    if sources.per_filetype[filetype] == nil then
      sources.per_filetype[filetype] = vim.deepcopy(ark_sources)
    end
  end

  sources_configured = true
end

function M.patch_blink_context()
  if context_patched then
    return
  end

  local ok_context, context = pcall(require, "blink.cmp.completion.trigger.context")
  if not ok_context or type(context.get_cursor) ~= "function" then
    return
  end

  local base_get_cursor = context.get_cursor
  context.get_cursor = function()
    local cursor = base_get_cursor()
    if vim.api.nvim_get_mode().mode ~= "i" then
      return cursor
    end

    local bufnr = vim.api.nvim_get_current_buf()
    if not in_ark_filetype(bufnr) then
      return cursor
    end

    local insert_col = vim.fn.col(".") - 1
    if type(insert_col) ~= "number" or insert_col < 0 then
      return cursor
    end

    local win_cursor = vim.api.nvim_win_get_cursor(0)
    if type(win_cursor) ~= "table" or type(win_cursor[1]) ~= "number" then
      return cursor
    end

    return { win_cursor[1], insert_col }
  end

  context_patched = true
end

function M.patch_blink_trigger()
  if trigger_patched then
    return
  end

  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  if not ok_trigger or type(trigger.show) ~= "function" then
    return
  end

  local base_show = trigger.show
  trigger.show = function(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    local trigger_kind = type(opts) == "table" and opts.trigger_kind or nil
    local trigger_character = type(opts) == "table" and opts.trigger_character or nil

    if not in_ark_filetype(bufnr)
      or trigger_kind ~= "trigger_character"
      or not (trigger_character == "$" or trigger_character == "@")
    then
      return base_show(opts)
    end

    if type(trigger.hide) == "function" then
      trigger.hide()
    end

    local scheduled_bufnr = bufnr
    local scheduled_opts = vim.deepcopy(opts or {})
    vim.defer_fn(function()
      if not vim.api.nvim_buf_is_valid(scheduled_bufnr) then
        return
      end
      if vim.api.nvim_get_current_buf() ~= scheduled_bufnr then
        return
      end
      if not active_ark_client(scheduled_bufnr) then
        return
      end

      base_show(scheduled_opts)
    end, 20)
  end

  trigger_patched = true
end

function M.patch_blink_selection()
  if selection_patched then
    return
  end

  local ok_config, blink_config = pcall(require, "blink.cmp.config")
  if not ok_config or type(blink_config.completion) ~= "table" then
    return
  end

  local list = blink_config.completion.list
  local selection = type(list) == "table" and list.selection or nil
  if type(selection) ~= "table" then
    return
  end

  local base_auto_insert = selection.auto_insert
  selection.auto_insert = function(context, items)
    local bufnr = vim.api.nvim_get_current_buf()
    if in_ark_filetype(bufnr) then
      return false
    end
    if type(base_auto_insert) == "function" then
      return base_auto_insert(context, items)
    end
    return base_auto_insert
  end

  selection_patched = true
end

function M.patch_blink_show()
  if show_patched then
    return
  end

  local ok_blink, blink = pcall(require, "blink.cmp")
  if not ok_blink or type(blink.show) ~= "function" then
    return
  end

  local base_show = blink.show
  blink.show = function(opts)
    local bufnr = vim.api.nvim_get_current_buf()
    if in_ark_filetype(bufnr) then
      close_blink_docs()
    end

    return base_show(opts)
  end

  show_patched = true
end

function M.patch_blink_menu_for_signature_help()
  if menu_patched then
    return
  end

  local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
  if not ok_menu or type(menu.update_position) ~= "function" then
    return
  end

  local base_update_position = menu.update_position
  menu.update_position = function(...)
    local result = base_update_position(...)
    local bufnr = vim.api.nvim_get_current_buf()
    local signature_win = current_signature_help_win()
    if signature_win ~= nil and in_ark_filetype(bufnr) then
      vim.schedule(function()
        resolve_signature_help_menu_collision(signature_win)
      end)
    end
    return result
  end

  menu_patched = true
end

function M.patch_signature_help_float()
  if signature_float_patched then
    return
  end

  local util = vim.lsp and vim.lsp.util or nil
  if type(util) ~= "table" or type(util.open_floating_preview) ~= "function" then
    return
  end

  local base_open_floating_preview = util.open_floating_preview
  util.open_floating_preview = function(contents, syntax, opts, ...)
    local bufnr = vim.api.nvim_get_current_buf()
    local is_signature_help = type(opts) == "table"
      and opts.focus_id == "textDocument/signatureHelp"
      and in_ark_filetype(bufnr)

    local fbuf, fwin = base_open_floating_preview(contents, syntax, opts, ...)
    if is_signature_help and type(fwin) == "number" and fwin ~= 0 then
      active_signature_help_win = fwin
      vim.schedule(function()
        close_blink_docs()
        resolve_signature_help_menu_collision(fwin)
      end)
    end
    return fbuf, fwin
  end

  signature_float_patched = true
end

function M.patch_blink_docs_for_signature_help()
  if docs_patched then
    return
  end

  local ok_docs, docs = pcall(require, "blink.cmp.completion.windows.documentation")
  if not ok_docs or type(docs) ~= "table" then
    return
  end

  local base_auto_show_item = type(docs.auto_show_item) == "function" and docs.auto_show_item or nil
  if base_auto_show_item ~= nil then
    docs.auto_show_item = function(context, item)
      if signature_help_visible() and in_ark_filetype(vim.api.nvim_get_current_buf()) then
        close_blink_docs()
        return
      end

      return base_auto_show_item(context, item)
    end
  end

  local base_show_item = type(docs.show_item) == "function" and docs.show_item or nil
  if base_show_item ~= nil then
    docs.show_item = function(context, item)
      if signature_help_visible() and in_ark_filetype(vim.api.nvim_get_current_buf()) then
        close_blink_docs()
        return
      end

      return base_show_item(context, item)
    end
  end

  docs_patched = true
end

function M.handle_insert_char_pre(bufnr, char)
  char = char or vim.v.char

  if (char == "$" or char == "@") and active_ark_client(bufnr) then
    hide_visible_blink_menu()
  end

  if char == "(" or char == "[" or char == "'" then
    vim.b[bufnr].ark_pending_pair_completion = char
    vim.defer_fn(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end
      M.maybe_show_after_pair(bufnr, char)
    end, 20)
  else
    vim.b[bufnr].ark_pending_pair_completion = nil
  end
end

function M.maybe_show_after_pair(bufnr, trigger_character)
  if type(trigger_character) ~= "string" or trigger_character == "" then
    trigger_character = vim.b[bufnr].ark_pending_pair_completion
  end
  if type(trigger_character) ~= "string" or trigger_character == "" then
    return
  end
  if vim.b[bufnr].ark_pending_pair_completion == trigger_character then
    vim.b[bufnr].ark_pending_pair_completion = nil
  end

  if not active_ark_client(bufnr) then
    return
  end

  if vim.api.nvim_get_mode().mode ~= "i" then
    return
  end

  local ok_blink, blink = pcall(require, "blink.cmp")
  if not ok_blink or blink.is_visible() then
    return
  end

  M.patch_blink_context()
  blink.show({
    providers = { "ark_lsp" },
  })
end

function M.maybe_hide_after_extractor(bufnr)
  if not active_ark_client(bufnr) then
    return
  end

  local mode = vim.api.nvim_get_mode().mode
  if mode ~= "i" then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local col = cursor[2]
  if type(col) ~= "number" or col <= 0 then
    return
  end

  local prev_char = line:sub(col, col)
  if prev_char ~= "$" and prev_char ~= "@" then
    return
  end

  hide_visible_blink_menu()
end

function M.register_lsp_commands()
  if commands_registered then
    return
  end

  vim.lsp.commands["ark.completeStringDelimiter"] = function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1] - 1
    local col = cursor[2]
    local line = vim.api.nvim_get_current_line()
    local char_under_cursor = line:sub(col + 1, col + 1)
    local delimiter = (char_under_cursor == "'" or char_under_cursor == '"') and char_under_cursor or '"'

    if char_under_cursor == delimiter then
      vim.api.nvim_win_set_cursor(0, { cursor[1], col + 1 })
      return
    end

    vim.api.nvim_buf_set_text(0, row, col, row, col, { delimiter })
    vim.api.nvim_win_set_cursor(0, { cursor[1], col + 1 })
  end

  commands_registered = true
end

return M
