vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local client_notifications = {}
local ui_notifications = {}
local clients = {}

local status_path = vim.fn.tempname() .. ".json"
vim.fn.writefile({
  vim.json.encode({
    status = "ready",
    repl_ready = true,
    repl_seq = 11,
    port = 9999,
    auth_token = "token",
  }),
}, status_path)

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
    return cmd, nil
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

package.loaded["ark.tmux"] = {
  startup_snapshot = function(_, opts)
    return {
      session = {
        tmux_socket = "/tmp/ark.sock",
        tmux_session = "project",
        tmux_pane = "%42",
      },
      status_path = status_path,
      startup_status_path = status_path,
      startup_status = {
        status = "ready",
        repl_ready = true,
        repl_seq = 11,
        port = 9999,
        auth_token = "token",
      },
      authoritative_status = {
        status = "ready",
        repl_ready = true,
        repl_seq = 11,
        port = 9999,
        auth_token = "token",
      },
      bridge_ready = opts and opts.validate_bridge == true or false,
      cmd_env = {
        ARK_SESSION_KIND = "ark",
        ARK_SESSION_STATUS_FILE = status_path,
        ARK_SESSION_TMUX_SOCKET = "/tmp/ark.sock",
        ARK_SESSION_TMUX_SESSION = "project",
        ARK_SESSION_TMUX_PANE = "%42",
        ARK_SESSION_TIMEOUT_MS = "1000",
      },
    }
  end,
}

local original_notify = vim.notify
local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_is_attached = vim.lsp.buf_is_attached
local original_stop_client = vim.lsp.stop_client

vim.notify = function(message, level, opts)
  ui_notifications[#ui_notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end

vim.lsp.start = function(config, opts)
  local id = 1
  clients[id] = {
    id = id,
    name = config.name,
    config = vim.deepcopy(config),
    initialized = false,
    attached_buffers = { [opts.bufnr] = true },
    is_stopped = function()
      return false
    end,
    notify = function(_, method, payload)
      client_notifications[#client_notifications + 1] = {
        method = method,
        payload = vim.deepcopy(payload),
      }
    end,
    request_sync = function(_, method)
      if method == "ark/internal/status" then
        return {
          result = {
            consoleScopeCount = 1,
            consoleScopeSymbolCount = 10,
            libraryPathCount = 2,
            sessionBridgeConfigured = true,
            detachedSessionStatus = {
              lastSessionUpdateStatus = "ready",
            },
          },
        }, nil
      end

      return {
        result = {
          hydrated = true,
        },
      }, nil
    end,
  }

  -- Simulate a real LSP process that starts successfully but initializes
  -- after ark.nvim's synchronous bootstrap wait window expires.
  vim.defer_fn(function()
    if clients[id] then
      clients[id].initialized = true
    end
  end, 150)

  return id
end

vim.lsp.get_clients = function(filter)
  local out = {}
  for _, client in pairs(clients) do
    if client.name == (filter and filter.name or client.name) then
      local matches_buf = not filter or not filter.bufnr or client.attached_buffers[filter.bufnr]
      local include_uninitialized = filter and filter._uninitialized == true
      if matches_buf and (include_uninitialized or client.initialized == true) then
        out[#out + 1] = client
      end
    end
  end
  return out
end

vim.lsp.get_client_by_id = function(id)
  return clients[id]
end

vim.lsp.buf_is_attached = function(bufnr, client_id)
  return clients[client_id] and clients[client_id].attached_buffers[bufnr] == true or false
end

vim.lsp.stop_client = function() end

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "r"

  local lsp = require("ark.lsp")
  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      root_markers = { ".git" },
      restart_wait_ms = 25,
    },
    tmux = {
      session_kind = "ark",
      bridge_wait_ms = 1000,
      session_timeout_ms = 1000,
    },
  }

  local client_id = lsp.start(opts, bufnr)
  if client_id ~= 1 then
    error("expected lsp.start to return client id 1, got " .. vim.inspect(client_id), 0)
  end

  -- A slow but healthy initialization should surface as a starting client,
  -- not as a bootstrap failure or total absence.
  local pending = lsp.status(opts, bufnr)
  if pending.available ~= false or pending.reason ~= "ark_lsp client is starting" then
    error("expected pending startup status, got " .. vim.inspect(pending), 0)
  end
  if pending.total_named_clients ~= 1 or pending.buffer_named_clients ~= 1 then
    error("expected pending client to be visible in status, got " .. vim.inspect(pending), 0)
  end
  if pending.clients[1] == nil or pending.clients[1].initialized ~= false then
    error("expected uninitialized client details in status, got " .. vim.inspect(pending), 0)
  end

  for _, notification in ipairs(ui_notifications) do
    if notification.message == "ark.nvim session bootstrap failed: ark_lsp client unavailable" then
      error("unexpected bootstrap failure while client is still starting", 0)
    end
  end

  local synced = vim.wait(1000, function()
    return #client_notifications > 0
  end, 20, false)
  if not synced then
    error("timed out waiting for session sync after delayed client init", 0)
  end

  local final = lsp.status(opts, bufnr, {
    timeout_ms = 50,
  })
  if final.available ~= true or final.sessionBridgeConfigured ~= true then
    error("expected final live client status, got " .. vim.inspect(final), 0)
  end
end)

vim.notify = original_notify
vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_is_attached = original_buf_is_attached
vim.lsp.stop_client = original_stop_client

if not ok then
  error(err, 0)
end
