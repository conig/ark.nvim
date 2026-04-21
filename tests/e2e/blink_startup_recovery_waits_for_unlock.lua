vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark"] = nil
package.loaded["ark.init"] = nil
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
  ensure_integration = function()
    return true
  end,
}
package.loaded["ark.snippets"] = {}
package.loaded["ark.view"] = {}

local hide_calls = 0
local show_calls = 0
local startup_ready_callback = nil

package.loaded["ark.blink"].handle_insert_char_pre = function() end
package.loaded["ark.blink"].maybe_hide_after_extractor = function()
  hide_calls = hide_calls + 1
end
package.loaded["ark.blink"].maybe_show_after_pair = function()
  show_calls = show_calls + 1
end

package.loaded["ark.bridge"] = {
  ensure_current_runtime = function()
    return true
  end,
  build_session_runtime = function()
    return true
  end,
}

package.loaded["ark.tmux"] = {
  start = function()
    return "%42", nil
  end,
  stop = function() end,
  status = function()
    return {
      inside_tmux = true,
      pane_id = "%42",
      managed = true,
      pane_exists = true,
      session = {
        tmux_socket = "/tmp/ark-test.sock",
        tmux_session = "ark-test",
        tmux_pane = "%42",
      },
      bridge_ready = false,
      repl_ready = false,
      tabs = {},
      tab_count = 1,
    }
  end,
  startup_status_authoritative = function()
    return nil
  end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function(callback)
    startup_ready_callback = callback
  end,
  prewarm = function()
    return 1
  end,
  start = function()
    return 1
  end,
  start_async = function()
    return 1
  end,
  status = function()
    return {
      available = false,
    }
  end,
}

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, "/tmp/ark_blink_startup_recovery_waits_for_unlock.R")
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = true,
    auto_start_lsp = true,
    async_startup = false,
    configure_slime = false,
  })

  -- Pair completion should not rely on startup-gated insert-mode recovery
  -- hooks anymore, so these events should stay quiet before unlock too.
  vim.api.nvim_exec_autocmds("CursorMovedI", {
    buffer = bufnr,
    modeline = false,
  })
  vim.api.nvim_exec_autocmds("TextChangedI", {
    buffer = bufnr,
    modeline = false,
  })
  vim.wait(50, function()
    return false
  end, 10, false)

  if hide_calls ~= 0 or show_calls ~= 0 then
    error(
      "expected insert-mode recovery hooks to stay idle before unlock, got "
        .. vim.inspect({ hide_calls = hide_calls, show_calls = show_calls }),
      0
    )
  end

  if type(startup_ready_callback) ~= "function" then
    error("expected ark.nvim to register a startup ready callback", 0)
  end

  startup_ready_callback(bufnr, {
    source = "LspBootstrap",
  })

  vim.api.nvim_exec_autocmds("CursorMovedI", {
    buffer = bufnr,
    modeline = false,
  })
  vim.api.nvim_exec_autocmds("TextChangedI", {
    buffer = bufnr,
    modeline = false,
  })

  vim.wait(50, function()
    return false
  end, 10, false)

  if hide_calls ~= 0 or show_calls ~= 0 then
    error(
      "expected insert-mode recovery hooks to stay idle after unlock, got "
        .. vim.inspect({ hide_calls = hide_calls, show_calls = show_calls }),
      0
    )
  end
end)

if not ok then
  error(err, 0)
end
