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

-- Comparison-string completions should come from Ark LSP only. Generic snippet,
-- path, and buffer sources leak unrelated items into `x == "` menus.
local comparison_context = {
  trigger = {
    initial_kind = "trigger_character",
    kind = "trigger_character",
    character = '"',
  },
  line = 'iris$Species == "',
  cursor = { 1, 18 },
}

local argument_context = {
  trigger = {
    initial_kind = "trigger_character",
    kind = "trigger_character",
    character = '"',
  },
  line = 'cor(mtcars, method = "',
  cursor = { 1, 23 },
}

local subset_context = {
  trigger = {
    initial_kind = "trigger_character",
    kind = "trigger_character",
    character = "[",
  },
  line = "dt_ark[",
  cursor = { 1, 7 },
}

local subset_string_context = {
  trigger = {
    initial_kind = "trigger_character",
    kind = "trigger_character",
    character = '"',
  },
  line = 'mtcars[, c("',
  cursor = { 1, 12 },
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

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(comparison_context) ~= true then
  error("ark_lsp should remain active for comparison-string trigger completions")
end

if type(added.ark_snippets.should_show_items) ~= "function" or added.ark_snippets.should_show_items(comparison_context) ~= false then
  error("ark_snippets should be suppressed for comparison-string trigger completions")
end

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(comparison_context) ~= false then
  error("ark_path should be suppressed for comparison-string trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(comparison_context) ~= false then
  error("ark_buffer should be suppressed for comparison-string trigger completions")
end

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(argument_context) ~= true then
  error("ark_lsp should remain active for argument-string trigger completions")
end

if type(added.ark_snippets.should_show_items) ~= "function" or added.ark_snippets.should_show_items(argument_context) ~= false then
  error("ark_snippets should be suppressed for argument-string trigger completions")
end

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(argument_context) ~= false then
  error("ark_path should be suppressed for argument-string trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(argument_context) ~= false then
  error("ark_buffer should be suppressed for argument-string trigger completions")
end

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(subset_context) ~= true then
  error("ark_lsp should remain active for subset trigger completions")
end

if type(added.ark_snippets.should_show_items) ~= "function" or added.ark_snippets.should_show_items(subset_context) ~= false then
  error("ark_snippets should be suppressed for subset trigger completions")
end

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(subset_context) ~= false then
  error("ark_path should be suppressed for subset trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(subset_context) ~= false then
  error("ark_buffer should be suppressed for subset trigger completions")
end

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(subset_string_context) ~= true then
  error("ark_lsp should remain active for subset-string trigger completions")
end

if type(added.ark_snippets.should_show_items) ~= "function" or added.ark_snippets.should_show_items(subset_string_context) ~= false then
  error("ark_snippets should be suppressed for subset-string trigger completions")
end

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(subset_string_context) ~= false then
  error("ark_path should be suppressed for subset-string trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(subset_string_context) ~= false then
  error("ark_buffer should be suppressed for subset-string trigger completions")
end
