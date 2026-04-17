vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark"] = nil
package.loaded["ark.init"] = nil
package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.bridge"] = nil

local prewarm_calls = 0
local start_calls = 0
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
  startup_status_authoritative = function()
    return nil
  end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function(callback)
    startup_ready_callback = callback
  end,
  prewarm = function(_, _)
    prewarm_calls = prewarm_calls + 1
    return 1
  end,
  start = function(_, bufnr)
    start_calls = start_calls + 1
    if type(startup_ready_callback) == "function" then
      startup_ready_callback(bufnr, {
        source = "LspBootstrap",
      })
    end
    return 1
  end,
  start_async = function()
    error("did not expect start_async() during sync startup prewarm", 0)
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
  vim.api.nvim_buf_set_name(bufnr, "/tmp/ark_sync_startup_marks_unlocked_on_bootstrap.R")
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

  local startup = ark.status().startup or {}
  if startup.main_buffer_unlock_source ~= "LspBootstrap" then
    error("expected startup unlock source LspBootstrap, got " .. vim.inspect(startup), 0)
  end
  if tonumber(startup.post_lsp_bootstrap_unlock_ms) ~= 0 then
    error("expected event-driven unlock to eliminate bootstrap tail, got " .. vim.inspect(startup), 0)
  end
  if prewarm_calls ~= 1 then
    error("expected exactly one sync prewarm call, got " .. tostring(prewarm_calls), 0)
  end
  if start_calls ~= 1 then
    error("expected exactly one sync lsp.start() call, got " .. tostring(start_calls), 0)
  end

  vim.print({
    prewarm_calls = prewarm_calls,
    start_calls = start_calls,
    startup = startup,
  })
end)

if not ok then
  error(err, 0)
end
