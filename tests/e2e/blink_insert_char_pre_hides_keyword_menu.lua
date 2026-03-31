package.loaded["ark.blink"] = nil

local hide_calls = 0

package.preload["blink.cmp"] = function()
  return {
    is_visible = function()
      return true
    end,
  }
end

package.preload["blink.cmp.completion.trigger"] = function()
  return {
    hide = function()
      hide_calls = hide_calls + 1
    end,
  }
end

local ark_blink = require("ark.blink")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
vim.bo[bufnr].filetype = "r"

local original_get_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
  if opts and opts.bufnr == bufnr and opts.name == "ark_lsp" then
    return { { id = 1, name = "ark_lsp" } }
  end
  return {}
end

ark_blink.handle_insert_char_pre(bufnr, "$")

vim.lsp.get_clients = original_get_clients

if hide_calls ~= 1 then
  error("expected InsertCharPre $ handling to synchronously hide the stale keyword menu")
end

if vim.b[bufnr].ark_pending_pair_completion ~= nil then
  error("extractor trigger should not leave pair-completion state behind")
end
