vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local status_calls = 0
local bridge_env_calls = 0
local bootstrap_requests = {}
local notifications = {}
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
  status = function()
    status_calls = status_calls + 1
    error("sync startup should not call tmux.status()", 0)
  end,
  bridge_env = function()
    bridge_env_calls = bridge_env_calls + 1
    error("sync startup should use startup snapshot env, not tmux.bridge_env()", 0)
  end,
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

local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_is_attached = vim.lsp.buf_is_attached
local original_stop_client = vim.lsp.stop_client

vim.lsp.start = function(config, opts)
  local id = 1
  clients[id] = {
    id = id,
    name = config.name,
    config = vim.deepcopy(config),
    initialized = true,
    attached_buffers = { [opts.bufnr] = true },
    is_stopped = function()
      return false
    end,
    notify = function(_, method, payload)
      notifications[#notifications + 1] = {
        method = method,
        payload = vim.deepcopy(payload),
      }
    end,
    request_sync = function(_, method, payload, timeout_ms, bufnr)
      bootstrap_requests[#bootstrap_requests + 1] = {
        method = method,
        payload = vim.deepcopy(payload),
        timeout_ms = timeout_ms,
        bufnr = bufnr,
      }
      return {
        result = {
          hydrated = true,
        },
      }, nil
    end,
  }
  return id
end

vim.lsp.get_clients = function(filter)
  local out = {}
  for _, client in pairs(clients) do
    if (not filter or not filter.name or filter.name == client.name)
      and (not filter or not filter.bufnr or client.attached_buffers[filter.bufnr])
    then
      out[#out + 1] = client
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
      restart_wait_ms = 0,
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

  if status_calls ~= 0 then
    error("expected sync startup to avoid tmux.status(), got " .. tostring(status_calls), 0)
  end
  if bridge_env_calls ~= 0 then
    error("expected sync startup to avoid tmux.bridge_env(), got " .. tostring(bridge_env_calls), 0)
  end
  if #bootstrap_requests ~= 1 then
    error("expected one bootstrap request, got " .. vim.inspect(bootstrap_requests), 0)
  end

  local request = bootstrap_requests[1]
  if request.method ~= "ark/internal/bootstrapSession" then
    error("expected bootstrap request, got " .. vim.inspect(request), 0)
  end
  if request.payload.tmuxSocket ~= "/tmp/ark.sock"
    or request.payload.tmuxSession ~= "project"
    or request.payload.tmuxPane ~= "%42"
    or request.payload.statusFile ~= status_path
    or request.payload.status ~= "ready"
    or request.payload.replReady ~= true
    or request.payload.replSeq ~= 11
  then
    error("unexpected bootstrap request payload: " .. vim.inspect(request), 0)
  end

  local settled = vim.wait(400, function()
    return #notifications > 0
  end, 20, false)
  if settled then
    error("expected sync startup to avoid initial session notifications, got " .. vim.inspect(notifications), 0)
  end
end)

vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_is_attached = original_buf_is_attached
vim.lsp.stop_client = original_stop_client

if not ok then
  error(err, 0)
end
