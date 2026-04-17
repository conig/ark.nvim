vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local bridge_env_calls = 0
local startup_snapshot_calls = 0
local notifications = {}
local clients = {}

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
    return cmd, nil
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

package.loaded["ark.tmux"] = {
  bridge_env = function()
    bridge_env_calls = bridge_env_calls + 1
    return {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = "/tmp/ark-test-session.json",
      ARK_SESSION_TMUX_SOCKET = "/tmp/ark-test.sock",
      ARK_SESSION_TMUX_SESSION = "ark-test",
      ARK_SESSION_TMUX_PANE = "%1",
      ARK_SESSION_TIMEOUT_MS = "1000",
    }
  end,
  startup_snapshot = function()
    startup_snapshot_calls = startup_snapshot_calls + 1
    return {
      bridge_ready = false,
    }
  end,
}

local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_stop_client = vim.lsp.stop_client

vim.lsp.start = function(config, _)
  local id = #notifications + 1
  local client = {
    id = id,
    config = vim.deepcopy(config),
    initialized = true,
    _stopped = false,
    is_stopped = function(self)
      return self._stopped == true
    end,
    notify = function(_, method, params)
      notifications[#notifications + 1] = {
        method = method,
        params = vim.deepcopy(params),
      }
    end,
  }
  clients[id] = client
  return id
end

vim.lsp.get_clients = function(_)
  local out = {}
  for _, client in pairs(clients) do
    if not client._stopped then
      out[#out + 1] = client
    end
  end
  return out
end

vim.lsp.get_client_by_id = function(id)
  return clients[id]
end

vim.lsp.stop_client = function(client_id)
  if clients[client_id] then
    clients[client_id]._stopped = true
  end
end

local ok, err = pcall(function()
  local lsp = require("ark.lsp")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_prewarm_avoids_session_sync.R")
  vim.bo[buf].filetype = "r"

  local client_id = lsp.prewarm({
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      root_markers = { ".git" },
      restart_wait_ms = 0,
    },
    tmux = {
      bridge_wait_ms = 1000,
    },
  }, buf)

  if client_id ~= 1 then
    error("expected prewarm to return client id 1, got " .. vim.inspect(client_id), 0)
  end

  local started_early = vim.wait(80, function()
    return vim.lsp.get_client_by_id(1) ~= nil
  end, 10, false)
  if not started_early then
    error("prewarm did not launch the detached lsp immediately", 0)
  end

  vim.wait(250, function()
    return false
  end, 25, false)

  if bridge_env_calls ~= 0 then
    error("expected prewarm to avoid synchronous tmux.bridge_env(), got " .. tostring(bridge_env_calls), 0)
  end

  if startup_snapshot_calls ~= 0 then
    error("expected prewarm to avoid tmux.startup_snapshot(), got " .. tostring(startup_snapshot_calls), 0)
  end

  if #notifications ~= 0 then
    error("expected prewarm to avoid background session notifications, saw " .. vim.inspect(notifications), 0)
  end

  local initial_env = clients[1].config.cmd_env or {}
  if next(initial_env) ~= nil then
    error("expected prewarm to launch a static detached lsp before session sync, got " .. vim.inspect(initial_env), 0)
  end

  vim.print({
    client_id = client_id,
    notifications = notifications,
  })
end)

vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.stop_client = original_stop_client

if not ok then
  error(err, 0)
end
