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

local trigger_context = {
  trigger = {
    initial_kind = "trigger_character",
    kind = "trigger_character",
    character = "$",
  },
}

local manual_context = {
  trigger = {
    initial_kind = "manual",
    kind = "manual",
  },
}

local keyword_context = {
  trigger = {
    initial_kind = "keyword",
    kind = "keyword",
  },
}

if type(added.ark_lsp) ~= "table" then
  error("ark_lsp provider should be registered for Ark filetypes")
end

if added.ark_snippets ~= nil then
  error("ark_snippets provider should not be registered for Ark filetypes")
end

if added.ark_path ~= nil then
  error("ark_path should not be registered for Ark filetypes")
end

if added.ark_buffer ~= nil then
  error("ark_buffer should not be registered for Ark filetypes")
end

if type(added.ark_lsp.min_keyword_length) ~= "function" then
  error("ark_lsp min_keyword_length policy missing")
end

if added.ark_lsp.min_keyword_length(trigger_context) ~= 0 then
  error("ark_lsp should allow zero-length trigger-character popup")
end

if added.ark_lsp.min_keyword_length(manual_context) ~= 0 then
  error("ark_lsp should allow zero-length manual popup")
end

if added.ark_lsp.min_keyword_length(keyword_context) ~= 1 then
  error("ark_lsp should keep normal keyword popup threshold")
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

  if #sources ~= 1 or sources[1] ~= "ark_lsp" then
    error("Ark filetypes should use ark_lsp as the only automatic source: " .. vim.inspect({
      filetype = filetype,
      sources = sources,
    }))
  end
end
