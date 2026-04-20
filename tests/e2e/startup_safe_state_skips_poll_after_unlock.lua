vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark"] = nil
package.loaded["ark.init"] = nil
package.loaded["ark.bridge"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.lsp"] = nil

local startup_snapshot_calls = 0
local lsp_status_calls = 0
local startup_ready_callback = nil

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
  set_startup_ready_callback = function(callback)
    startup_ready_callback = callback
  end,
  prewarm = function()
    return 1
  end,
  start = function(_, bufnr)
    if type(startup_ready_callback) == "function" then
      startup_ready_callback(bufnr, {
        source = "LspBootstrapImmediate",
      })
    end
    return 1
  end,
  start_async = function()
    error("did not expect async lsp start in sync startup test", 0)
  end,
  status = function()
    lsp_status_calls = lsp_status_calls + 1
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
  vim.api.nvim_buf_set_name(bufnr, "/tmp/ark_startup_safe_state_skips_poll_after_unlock.R")
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = true,
    auto_start_lsp = true,
    async_startup = false,
    configure_slime = false,
  })

  local unlocked = vim.wait(1000, function()
    local startup = ark.status().startup or {}
    return startup.main_buffer_unlocked == true
  end, 20, false)
  if not unlocked then
    error("timed out waiting for startup unlock", 0)
  end

  startup_snapshot_calls = 0
  lsp_status_calls = 0

  vim.api.nvim_exec_autocmds("SafeState", {
    modeline = false,
  })

  if startup_snapshot_calls ~= 0 or lsp_status_calls ~= 0 then
    error(
      "expected SafeState after startup unlock to avoid readiness polling, got "
        .. vim.inspect({
          startup_snapshot_calls = startup_snapshot_calls,
          lsp_status_calls = lsp_status_calls,
          startup = ark.status().startup,
        }),
      0
    )
  end
end)

if not ok then
  error(err, 0)
end
