package.loaded["ark.blink"] = nil

local blink_show_calls = {}
local trigger_show_calls = {}

package.preload["blink.cmp"] = function()
  return {
    is_visible = function()
      return false
    end,
    show = function(opts)
      blink_show_calls[#blink_show_calls + 1] = opts
      return true
    end,
  }
end

package.preload["blink.cmp.completion.trigger"] = function()
  return {
    show = function(opts)
      trigger_show_calls[#trigger_show_calls + 1] = opts
      return true
    end,
  }
end

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

local original_defer_fn = vim.defer_fn
vim.defer_fn = function(callback, _)
  callback()
end

local original_get_mode = vim.api.nvim_get_mode
vim.api.nvim_get_mode = function()
  return { mode = "i" }
end

local original_get_current_buf = vim.api.nvim_get_current_buf
vim.api.nvim_get_current_buf = function()
  return bufnr
end

local original_buf_is_valid = vim.api.nvim_buf_is_valid
vim.api.nvim_buf_is_valid = function(candidate)
  return candidate == bufnr
end

local ark_blink = require("ark.blink")
ark_blink.handle_insert_char_pre(bufnr, "'")

vim.lsp.get_clients = original_get_clients
vim.defer_fn = original_defer_fn
vim.api.nvim_get_mode = original_get_mode
vim.api.nvim_get_current_buf = original_get_current_buf
vim.api.nvim_buf_is_valid = original_buf_is_valid

if #blink_show_calls ~= 0 then
  error("single-quote pair completion should not call blink.show(): " .. vim.inspect(blink_show_calls))
end

if #trigger_show_calls ~= 1 then
  error("expected a single trigger.show() call for single-quote pair completion, got " .. vim.inspect(trigger_show_calls))
end

local trigger = trigger_show_calls[1] or {}
if trigger.trigger_kind ~= "trigger_character" or trigger.trigger_character ~= "'" then
  error("single-quote pair completion should use the direct trigger-character path: " .. vim.inspect(trigger_show_calls))
end
