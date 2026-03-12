local M = {}
local commands_registered = false

local function active_ark_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })
  return clients[1] ~= nil
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
