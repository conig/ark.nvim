vim.opt.rtp:prepend(vim.fn.getcwd())

local test = require("tests.e2e.ark_test")

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local notifications = {}
local session_notifications = {}
local request_sync_calls = 0
local async_requests = 0
local startup_ready = nil
local client = nil

local status_path = vim.fn.tempname() .. ".json"
vim.fn.writefile({
  vim.json.encode({
    status = "ready",
    repl_ready = true,
    repl_seq = 1,
    port = 9999,
    auth_token = "token",
  }),
}, status_path)

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
    return vim.deepcopy(cmd), nil
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

package.loaded["ark.tmux"] = {
  bridge_env = function()
    return nil
  end,
  session = function()
    return {
      tmux_socket = "/tmp/ark-test.sock",
      tmux_session = "ark-test",
      tmux_pane = "%42",
    }
  end,
  session_id = function()
    return "async-bootstrap-session"
  end,
  startup_snapshot = function()
    return {
      session = {
        tmux_socket = "/tmp/ark-test.sock",
        tmux_session = "ark-test",
        tmux_pane = "%42",
      },
      status_path = status_path,
      startup_status_path = status_path,
      startup_status = {
        status = "ready",
        repl_ready = true,
        repl_seq = 1,
        port = 9999,
        auth_token = "token",
      },
      authoritative_status = {
        status = "ready",
        repl_ready = true,
        repl_seq = 1,
        port = 9999,
        auth_token = "token",
      },
      bridge_ready = false,
    }
  end,
  startup_status_path = function()
    return status_path
  end,
  startup_status_authoritative = function()
    return {
      status = "ready",
      repl_ready = true,
      repl_seq = 1,
      port = 9999,
      auth_token = "token",
    }
  end,
}

local original_notify = vim.notify
local original_start = vim.lsp.start
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_get_clients = vim.lsp.get_clients
local original_buf_is_attached = vim.lsp.buf_is_attached
local original_stop_client = vim.lsp.stop_client

vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end

vim.lsp.start = function(config, start_opts)
  client = {
    id = 91,
    name = config.name,
    initialized = true,
    config = vim.deepcopy(config),
    attached_buffers = { [start_opts.bufnr] = true },
    is_stopped = function()
      return false
    end,
    notify = function(_, method, params)
      session_notifications[#session_notifications + 1] = {
        method = method,
        params = vim.deepcopy(params),
      }
    end,
    request_sync = function()
      request_sync_calls = request_sync_calls + 1
      return nil, "timeout"
    end,
    request = function(_, method, params, callback)
      async_requests = async_requests + 1
      local request_id = async_requests
      vim.defer_fn(function()
        if request_id == 1 then
          callback("timeout", nil)
        else
          callback(nil, {
            hydrated = true,
          })
        end
      end, 20)
      return true, request_id
    end,
    cancel_request = function() end,
  }
  return client.id
end

vim.lsp.get_client_by_id = function(client_id)
  if client and client_id == client.id then
    return client
  end
  return nil
end

vim.lsp.get_clients = function(filter)
  if not client then
    return {}
  end
  if type(filter) == "table" and filter.name and filter.name ~= client.name then
    return {}
  end
  if type(filter) == "table" and filter.bufnr and not client.attached_buffers[filter.bufnr] then
    return {}
  end
  return { client }
end

vim.lsp.buf_is_attached = function(bufnr, client_id)
  return client ~= nil and client.id == client_id and client.attached_buffers[bufnr] == true
end

vim.lsp.stop_client = function() end

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "r"

  local lsp = require("ark.lsp")
  lsp.set_startup_ready_callback(function(callback_bufnr, payload)
    startup_ready = {
      bufnr = callback_bufnr,
      payload = vim.deepcopy(payload),
    }
  end)

  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      restart_wait_ms = 25,
      root_markers = {},
    },
    tmux = {
      bridge_wait_ms = 1000,
      session_timeout_ms = 1000,
      session_kind = "ark",
    },
  }

  local client_id = lsp.start(opts, bufnr, {
    wait_for_client = false,
  })
  if client_id ~= 91 then
    test.fail("expected async lsp.start() to return fake client id, got " .. vim.inspect(client_id))
  end

  test.wait_for("async bootstrap retry", 2000, function()
    return startup_ready ~= nil or request_sync_calls > 0
  end)

  -- The console path starts LSP asynchronously. Bootstrap retries in that path
  -- must not call request_sync(), because a slow first bootstrap can block the
  -- TUI and then display a stale timeout warning even if the next retry works.
  if request_sync_calls ~= 0 then
    test.fail("async startup bootstrap used request_sync(): " .. tostring(request_sync_calls))
  end

  test.wait_for("async bootstrap success", 2000, function()
    return startup_ready ~= nil
  end)

  if async_requests < 2 then
    test.fail("expected async bootstrap to retry after a transient timeout, got " .. tostring(async_requests))
  end
  if startup_ready.payload.source ~= "LspBootstrapRetry" then
    test.fail("expected retry startup-ready source, got " .. vim.inspect(startup_ready))
  end
  for _, notification in ipairs(notifications) do
    if tostring(notification.message):find("ark.nvim session bootstrap failed", 1, true) then
      test.fail("transient async bootstrap timeout should not notify after retry success: " .. vim.inspect(notifications))
    end
  end
  if #session_notifications == 0 then
    test.fail("expected session update notification before async bootstrap")
  end
end)

vim.notify = original_notify
vim.lsp.start = original_start
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.get_clients = original_get_clients
vim.lsp.buf_is_attached = original_buf_is_attached
vim.lsp.stop_client = original_stop_client
package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

if not ok then
  error(err, 0)
end
