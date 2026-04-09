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
      },
      per_filetype = {},
    },
  }
end

local ark_blink = require("ark.blink")
ark_blink.configure_blink_sources()
local blink_config = require("blink.cmp.config")

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

if added.ark_snippets ~= nil then
  error("ark_snippets provider should not be registered for Ark filetypes")
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

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(comparison_context) ~= false then
  error("ark_path should be suppressed for comparison-string trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(comparison_context) ~= false then
  error("ark_buffer should be suppressed for comparison-string trigger completions")
end

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(argument_context) ~= true then
  error("ark_lsp should remain active for argument-string trigger completions")
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

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(subset_context) ~= false then
  error("ark_path should be suppressed for subset trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(subset_context) ~= false then
  error("ark_buffer should be suppressed for subset trigger completions")
end

if type(added.ark_lsp.should_show_items) ~= "function" or added.ark_lsp.should_show_items(subset_string_context) ~= true then
  error("ark_lsp should remain active for subset-string trigger completions")
end

if type(added.ark_path.should_show_items) ~= "function" or added.ark_path.should_show_items(subset_string_context) ~= false then
  error("ark_path should be suppressed for subset-string trigger completions")
end

if type(added.ark_buffer.should_show_items) ~= "function" or added.ark_buffer.should_show_items(subset_string_context) ~= false then
  error("ark_buffer should be suppressed for subset-string trigger completions")
end

local per_filetype = blink_config.sources.per_filetype or {}
for _, filetype in ipairs({ "r", "rmd", "qmd", "quarto" }) do
  local sources = per_filetype[filetype]
  if sources == nil then
    error("missing Ark Blink source override for filetype " .. filetype)
  end

  for _, source in ipairs(sources) do
    if source == "ark_snippets" or source == "snippets" then
      error("unexpected snippet source in Ark Blink filetype list for " .. filetype)
    end
  end
end
