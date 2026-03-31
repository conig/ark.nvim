package.loaded["blink.cmp.config"] = nil

local ark_blink = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/lua/ark/blink.lua"))

local blink_config = {
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

package.loaded["blink.cmp.config"] = blink_config

ark_blink.patch_blink_selection()

vim.bo.filetype = "r"

local extractor_context = {
  trigger = {
    kind = "trigger_character",
    initial_kind = "trigger_character",
    character = "$",
    initial_character = "$",
  },
}

local keyword_context = {
  trigger = {
    kind = "keyword",
    initial_kind = "keyword",
  },
}

local selection = blink_config.completion.list.selection
if type(selection.auto_insert) ~= "function" then
  error("auto_insert policy missing")
end

if selection.auto_insert(extractor_context, { { label = "mpg" } }) ~= false then
  error("extractor auto_insert should be disabled in Ark buffers")
end

if selection.auto_insert(keyword_context, { { label = "mtcars" } }) ~= true then
  error("non-extractor auto_insert should preserve base behavior")
end
