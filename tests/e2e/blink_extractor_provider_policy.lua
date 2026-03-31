package.loaded["ark.blink"] = nil

local added = {}

package.preload["blink.cmp"] = function()
  return {
    add_source_provider = function(id, provider)
      added[id] = provider
    end,
  }
end

package.preload["blink.cmp.config"] = function()
  return {
    sources = {
      providers = {
        lsp = {},
        buffer = {},
        path = {},
        snippets = {},
      },
      per_filetype = {},
    },
  }
end

local ark_blink = require("ark.blink")
ark_blink.configure_blink_sources()

local extractor_context = {
  trigger = {
    initial_kind = "trigger_character",
    kind = "trigger_character",
    character = "$",
  },
  line = "mylist$",
  cursor = { 1, 7 },
}

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(extractor_context) ~= true then
  error("ark_lsp should remain active for extractor trigger completions")
end

if type(added.ark_snippets.should_show_items) ~= "function" or added.ark_snippets.should_show_items(extractor_context) ~= false then
  error("ark_snippets should be suppressed for extractor trigger completions")
end

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(extractor_context) ~= false then
  error("ark_path should be suppressed for extractor trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(extractor_context) ~= false then
  error("ark_buffer should be suppressed for extractor trigger completions")
end
