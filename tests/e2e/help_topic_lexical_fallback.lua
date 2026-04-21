vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil

local requested_method = nil
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_is_attached = vim.lsp.buf_is_attached

local client = {
  id = 1,
  name = "ark_lsp",
  initialized = true,
  is_stopped = function()
    return false
  end,
  request_sync = function(_, method)
    requested_method = method
    return {
      result = vim.NIL,
    }, nil
  end,
}

vim.lsp.get_clients = function(filter)
  if filter and filter.name and filter.name ~= "ark_lsp" then
    return {}
  end
  return { client }
end

vim.lsp.get_client_by_id = function(id)
  if id == 1 then
    return client
  end
  return nil
end

vim.lsp.buf_is_attached = function(_, client_id)
  return client_id == 1
end

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = "r"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "dplyr::mutate(mtcars)" })
  vim.api.nvim_win_set_cursor(0, { 1, 10 })

  local topic, topic_err = require("ark.lsp").help_topic({
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
    },
  }, bufnr)

  if topic ~= nil then
    error("help topic lookup should not fall back to lexical extraction: " .. vim.inspect(topic), 0)
  end

  if topic_err ~= "no help topic found" then
    error("expected native help topic failure to surface directly, got " .. vim.inspect(topic_err), 0)
  end

  if requested_method ~= "ark/textDocument/helpTopic" then
    error("expected ark-native help topic method, got " .. vim.inspect(requested_method), 0)
  end
end)

vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_is_attached = original_buf_is_attached

if not ok then
  error(err, 0)
end
