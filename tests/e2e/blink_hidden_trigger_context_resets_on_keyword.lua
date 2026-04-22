package.loaded["ark.blink"] = nil

local show_calls = {}

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
      return false
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

ark_blink.patch_blink_trigger()

local trigger = require("blink.cmp.completion.trigger")
trigger.show({
  trigger_kind = "keyword",
})

if #show_calls ~= 1 then
  error("expected wrapped keyword show to call Blink once")
end

if show_calls[1].context_before ~= nil then
  error("hidden trigger-character context should be cleared before Ark keyword show: " .. vim.inspect(show_calls[1]))
end
