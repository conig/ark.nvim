package.loaded["ark.blink"] = nil

local show_calls = {}
local visible = true

local trigger_module
trigger_module = {
  context = {
    id = 41,
    trigger = {
      initial_kind = "trigger_character",
      initial_character = " ",
      kind = "trigger_character",
      character = " ",
    },
  },
  show = function(opts)
    show_calls[#show_calls + 1] = {
      opts = vim.deepcopy(opts),
      context_before = trigger_module.context and vim.deepcopy(trigger_module.context) or nil,
    }
  end,
  hide = function() end,
}

package.preload["blink.cmp"] = function()
  return {
    add_source_provider = function() end,
    is_visible = function()
      return visible
    end,
  }
end

package.preload["blink.cmp.config"] = function()
  return {
    sources = {
      providers = {
        lsp = {},
      },
      per_filetype = {},
    },
  }
end

package.preload["blink.cmp.completion.trigger"] = function()
  return trigger_module
end

local ark_blink = require("ark.blink")
vim.bo.filetype = "rmd"
vim.api.nvim_set_current_line("plain_identifier")

ark_blink.patch_blink_trigger()

local trigger = require("blink.cmp.completion.trigger")
trigger.show({
  trigger_kind = "keyword",
})

if #show_calls ~= 1 then
  error("expected wrapped keyword show to call Blink once")
end

if show_calls[1].context_before ~= nil then
  error("trigger-character context should be cleared before every Ark keyword show: " .. vim.inspect(show_calls[1]))
end

local original_get_clients = vim.lsp.get_clients
local original_get_mode = vim.api.nvim_get_mode
vim.lsp.get_clients = function()
  return { { id = 1, name = "ark_lsp" } }
end
vim.api.nvim_get_mode = function()
  return { mode = "i" }
end
vim.api.nvim_set_current_line("")
visible = false
trigger_module.context = nil
ark_blink.maybe_show_after_startup(vim.api.nvim_get_current_buf())
vim.lsp.get_clients = original_get_clients
vim.api.nvim_get_mode = original_get_mode

if #show_calls ~= 2 or show_calls[2].opts.trigger_kind ~= "keyword" then
  error("startup recovery should delegate completion intent to Blink/LSP without parsing buffer text")
end
