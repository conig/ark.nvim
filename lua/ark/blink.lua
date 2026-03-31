local M = {}
local commands_registered = false
local context_patched = false
local sources_configured = false
local trigger_patched = false

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
  if is_extractor_trigger(context) then
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

  if type(providers.snippets) == "table" and providers.ark_snippets == nil then
    blink.add_source_provider("ark_snippets", ark_provider(providers.snippets, {
      min_keyword_length = ark_auto_keyword_min_length,
      should_show_items = ark_should_show_non_lsp_items,
    }))
  end

  sources.per_filetype = sources.per_filetype or {}

  local ark_sources = { "ark_lsp", inherit_defaults = false }
  if providers.ark_path ~= nil or providers.path ~= nil then
    ark_sources[#ark_sources + 1] = "ark_path"
  end
  if providers.ark_snippets ~= nil or providers.snippets ~= nil then
    ark_sources[#ark_sources + 1] = "ark_snippets"
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

function M.handle_insert_char_pre(bufnr, char)
  char = char or vim.v.char

  if (char == "$" or char == "@") and active_ark_client(bufnr) then
    hide_visible_blink_menu()
  end

  if char == "(" or char == "[" then
    vim.b[bufnr].ark_pending_pair_completion = char
  else
    vim.b[bufnr].ark_pending_pair_completion = nil
  end
end

function M.maybe_show_after_pair(bufnr)
  local trigger_character = vim.b[bufnr].ark_pending_pair_completion
  if type(trigger_character) ~= "string" or trigger_character == "" then
    return
  end
  vim.b[bufnr].ark_pending_pair_completion = nil

  if not active_ark_client(bufnr) then
    return
  end

  local ok_blink, blink = pcall(require, "blink.cmp")
  if not ok_blink or blink.is_visible() then
    return
  end

  M.patch_blink_context()

  local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
  if not ok_trigger then
    return
  end

  trigger.show({
    trigger_kind = "trigger_character",
    trigger_character = trigger_character,
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

    if char_under_cursor == '"' then
      vim.api.nvim_win_set_cursor(0, { cursor[1], col + 1 })
      return
    end

    vim.api.nvim_buf_set_text(0, row, col, row, col, { '"' })
    vim.api.nvim_win_set_cursor(0, { cursor[1], col + 1 })
  end

  commands_registered = true
end

return M
