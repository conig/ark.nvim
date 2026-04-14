vim.opt.rtp:prepend(vim.fn.getcwd())

local status_dir = vim.fn.tempname()
vim.fn.mkdir(status_dir, "p")

local status_path = status_dir .. "/session.json"
local current_status = {
  status = "pending",
  repl_ready = false,
}
local bridge_env_calls = 0
local startup_snapshot_calls = 0

vim.fn.writefile({ vim.json.encode(current_status) }, status_path)

package.loaded["ark.tmux"] = {
  bridge_env = function()
    bridge_env_calls = bridge_env_calls + 1
    return {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = status_path,
      ARK_SESSION_TMUX_SOCKET = "/tmp/ark-test.sock",
      ARK_SESSION_TMUX_SESSION = "ark-test",
      ARK_SESSION_TMUX_PANE = "%1",
      ARK_SESSION_TIMEOUT_MS = "1000",
    }
  end,
  session = function()
    return {
      tmux_socket = "/tmp/ark-test.sock",
      tmux_session = "ark-test",
      tmux_pane = "%1",
    }
  end,
  startup_snapshot = function()
    startup_snapshot_calls = startup_snapshot_calls + 1
    return {
      bridge_ready = false,
      session = {
        tmux_socket = "/tmp/ark-test.sock",
        tmux_session = "ark-test",
        tmux_pane = "%1",
      },
      startup_status = vim.deepcopy(current_status),
      authoritative_status = vim.deepcopy(current_status),
      status_path = status_path,
      cmd_env = {
        ARK_SESSION_KIND = "ark",
        ARK_SESSION_STATUS_FILE = status_path,
        ARK_SESSION_TMUX_SOCKET = "/tmp/ark-test.sock",
        ARK_SESSION_TMUX_SESSION = "ark-test",
        ARK_SESSION_TMUX_PANE = "%1",
        ARK_SESSION_TIMEOUT_MS = "1000",
      },
    }
  end,
  startup_status = function()
    return vim.deepcopy(current_status)
  end,
  startup_status_authoritative = function()
    return vim.deepcopy(current_status)
  end,
  startup_status_path = function()
    return status_path
  end,
}
package.loaded["ark.lsp"] = nil

local started = {}
local stopped = {}
local notifications = {}
local clients = {}

local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_stop_client = vim.lsp.stop_client

vim.lsp.start = function(config, _)
  local id = #started + 1
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

  started[#started + 1] = vim.deepcopy(config)
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
  stopped[#stopped + 1] = client_id
  if clients[client_id] then
    clients[client_id]._stopped = true
  end
end

local ok, err = pcall(function()
  local lsp = require("ark.lsp")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_async_startup_notification.R")
  vim.bo[buf].filetype = "r"

  lsp.start_async({
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

  local started_early = vim.wait(80, function()
    return #started > 0
  end, 10, false)
  if not started_early then
    error("async startup did not launch the static LSP immediately", 0)
  end

  if #started ~= 1 then
    error("expected exactly one initial LSP start, saw " .. #started, 0)
  end

  if bridge_env_calls ~= 0 then
    error("expected async startup to avoid synchronous tmux.bridge_env(), got " .. tostring(bridge_env_calls), 0)
  end

  if startup_snapshot_calls ~= 0 then
    error("expected async startup to avoid synchronous tmux.startup_snapshot(), got " .. tostring(startup_snapshot_calls), 0)
  end

  local initial_env = started[1].cmd_env or {}
  if next(initial_env) ~= nil then
    error("expected async startup to launch a static detached LSP before session sync, got " .. vim.inspect(initial_env), 0)
  end

  local notified_pending = vim.wait(1000, function()
    return #notifications > 0
  end, 10, false)
  if not notified_pending then
    error("timed out waiting for initial session notification", 0)
  end

  vim.defer_fn(function()
    current_status = {
      status = "ready",
      port = 43123,
      auth_token = "ark-test-token",
      repl_ready = true,
    }
    vim.fn.writefile({ vim.json.encode(current_status) }, status_path)
  end, 150)

  local ready_ok = vim.wait(1200, function()
    local last = notifications[#notifications]
    return last
      and last.method == "ark/updateSession"
      and last.params
      and last.params.replReady == true
  end, 10, false)
  if not ready_ok then
    error("timed out waiting for the ready session notification", 0)
  end

  if #stopped ~= 0 then
    error("expected no stop/start churn during async startup session updates, saw " .. #stopped .. " stops", 0)
  end

  vim.print({
    starts = #started,
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
