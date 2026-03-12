local M = {}

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

return M
