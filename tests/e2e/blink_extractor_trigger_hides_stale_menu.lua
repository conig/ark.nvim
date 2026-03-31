package.loaded["ark.blink"] = nil

local hide_calls = 0
local show_calls = {}

package.preload["blink.cmp.completion.trigger"] = function()
  return {
    show = function(opts)
      show_calls[#show_calls + 1] = opts
      return opts
    end,
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

ark_blink.patch_blink_trigger()

local trigger = require("blink.cmp.completion.trigger")

trigger.show({
  trigger_kind = "trigger_character",
  trigger_character = "$",
})

if hide_calls ~= 1 then
  error("expected extractor trigger to synchronously hide stale menu before deferred show")
end

if #show_calls ~= 0 then
  error("expected deferred extractor show, but base show ran synchronously")
end

local deferred_ok = vim.wait(100, function()
  return #show_calls == 1
end, 10, false)

vim.lsp.get_clients = original_get_clients

if not deferred_ok then
  error("expected deferred extractor show to run")
end

if show_calls[1].trigger_character ~= "$" or show_calls[1].trigger_kind ~= "trigger_character" then
  error("deferred extractor show lost trigger context: " .. vim.inspect(show_calls[1]))
end
