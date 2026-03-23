local M = {}
local commands_registered = false
local context_patched = false
local sources_configured = false

local ark_filetypes = { "r", "rmd", "qmd", "quarto" }

local function active_ark_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })
  return clients[1] ~= nil
end

local function in_ark_filetype(bufnr)
  local filetype = vim.bo[bufnr].filetype
  return vim.tbl_contains(ark_filetypes, filetype)
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
      should_show_items = ark_should_show_auto_items,
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
      should_show_items = ark_should_show_auto_items,
    }))
  end

  if type(providers.snippets) == "table" and providers.ark_snippets == nil then
    blink.add_source_provider("ark_snippets", ark_provider(providers.snippets, {
      min_keyword_length = ark_auto_keyword_min_length,
      should_show_items = ark_should_show_auto_items,
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

function M.record_insert_char(bufnr)
  if vim.v.char == "(" or vim.v.char == "[" then
    vim.b[bufnr].ark_pending_pair_completion = vim.v.char
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
