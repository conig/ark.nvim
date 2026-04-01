package.loaded["blink.cmp.config"] = {
  completion = {
    list = {
      selection = {
        auto_insert = function()
          return true
        end,
      },
    },
  },
}

local ark_blink = require("ark.blink")
ark_blink.patch_blink_selection()

local selection = require("blink.cmp.config").completion.list.selection

local extractor_context = {
  trigger = {
    kind = "trigger_character",
    initial_kind = "trigger_character",
    character = "$",
  },
}

local comparison_context = {
  trigger = {
    kind = "trigger_character",
    initial_kind = "trigger_character",
    character = '"',
  },
}

local keyword_context = {
  trigger = {
    kind = "keyword",
    initial_kind = "keyword",
  },
}

vim.bo.filetype = "r"

if type(selection.auto_insert) ~= "function" then
  error("auto_insert policy missing")
end

-- In Ark buffers, selection movement must not rewrite the buffer. Accept should
-- be explicit regardless of whether the menu came from $, comparison strings,
-- or ordinary keyword completion.
if selection.auto_insert(extractor_context, { { label = "mpg" } }) ~= false then
  error("extractor auto_insert should be disabled in Ark buffers")
end

if selection.auto_insert(comparison_context, { { label = "setosa" } }) ~= false then
  error("comparison auto_insert should be disabled in Ark buffers")
end

if selection.auto_insert(keyword_context, { { label = "iris" } }) ~= false then
  error("keyword auto_insert should be disabled in Ark buffers")
end

vim.bo.filetype = "lua"

if selection.auto_insert(keyword_context, { { label = "vim" } }) ~= true then
  error("non-Ark auto_insert should preserve base behavior")
end
