vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark"] = nil
package.loaded["ark.blink"] = {
  configure_blink_sources = function() end,
  register_lsp_commands = function() end,
  patch_blink_context = function() end,
  patch_blink_selection = function() end,
  patch_blink_show = function() end,
  patch_blink_menu_for_signature_help = function() end,
  patch_blink_docs_for_signature_help = function() end,
  patch_signature_help_float = function() end,
  patch_blink_trigger = function() end,
  handle_insert_char_pre = function() end,
  maybe_hide_after_extractor = function() end,
  maybe_show_after_pair = function() end,
}
package.loaded["ark.snippets"] = {}
package.loaded["ark.view"] = {}
package.loaded["ark.bridge"] = {
  ensure_current_runtime = function()
    return true
  end,
  build_session_runtime = function()
    return true
  end,
}

local lsp_calls = {}
local sync_calls = 0
local tmux_started_after_lsp = false

package.loaded["ark.lsp"] = {
  prewarm = function(_, bufnr)
    lsp_calls[#lsp_calls + 1] = {
      method = "prewarm",
      bufnr = bufnr,
    }
    return 1
  end,
  start_async = function(_, bufnr)
    lsp_calls[#lsp_calls + 1] = {
      method = "start_async",
      bufnr = bufnr,
    }
    return 1
  end,
  sync_sessions = function()
    sync_calls = sync_calls + 1
  end,
}

package.loaded["ark.tmux"] = {
  start = function()
    tmux_started_after_lsp = #lsp_calls > 0
    return "%42", nil
  end,
  stop = function() end,
  status = function()
    return {
      pane_exists = false,
      bridge_ready = false,
      repl_ready = false,
      tabs = {},
      tab_count = 0,
      managed = false,
      inside_tmux = true,
    }
  end,
}

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    configure_slime = false,
  })

  local pane_id = ark.start_pane()
  if pane_id ~= "%42" then
    error("expected start_pane() to return tmux pane id, got " .. vim.inspect(pane_id), 0)
  end

  -- Command-driven startup should prewarm the detached LSP for the current
  -- R buffer before the managed pane path returns, so user configs that call
  -- `start_pane()` and then `start_lsp()` do not serialize those phases.
  if not tmux_started_after_lsp then
    error("expected start_pane() to prewarm the detached lsp before tmux.start()", 0)
  end

  if #lsp_calls ~= 1 or lsp_calls[1].bufnr ~= bufnr or lsp_calls[1].method ~= "prewarm" then
    error("expected start_pane() to prewarm the current buffer LSP, got " .. vim.inspect(lsp_calls), 0)
  end

  if sync_calls ~= 1 then
    error("expected start_pane() to sync sessions after startup, got " .. tostring(sync_calls), 0)
  end
end)

package.loaded["ark"] = nil

if not ok then
  error(err, 0)
end
