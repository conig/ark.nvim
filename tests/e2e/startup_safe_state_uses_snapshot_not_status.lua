vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark"] = nil
package.loaded["ark.init"] = nil
package.loaded["ark.snippets"] = {}
package.loaded["ark.view"] = {}
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

local status_calls = 0
local startup_snapshot_calls = 0

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
    status_calls = status_calls + 1
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
      bridge_ready = true,
      repl_ready = true,
      tabs = {},
      tab_count = 1,
    }
  end,
  startup_snapshot = function()
    startup_snapshot_calls = startup_snapshot_calls + 1
    return {
      bridge_ready = true,
      startup_status = {
        repl_ready = true,
      },
    }
  end,
  startup_status_authoritative = function()
    return nil
  end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function() end,
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
      available = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
        lastBootstrapSuccessMs = 1,
      },
    }
  end,
}

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, "/tmp/ark_startup_safe_state_uses_snapshot_not_status.R")
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = true,
    auto_start_lsp = true,
    async_startup = false,
    configure_slime = false,
  })

  vim.api.nvim_exec_autocmds("SafeState", {
    modeline = false,
  })

  if status_calls ~= 0 then
    error("expected SafeState startup unlock to avoid backend status(), got " .. tostring(status_calls), 0)
  end

  if startup_snapshot_calls == 0 then
    error("expected SafeState startup unlock to consult the startup snapshot", 0)
  end

  local startup = ark.status().startup or {}
  if startup.main_buffer_unlocked ~= true or startup.main_buffer_unlock_source ~= "SafeState" then
    error("expected SafeState to unlock startup, got " .. vim.inspect(startup), 0)
  end
end)

if not ok then
  error(err, 0)
end
