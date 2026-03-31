vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local status_calls = 0
local notifications = {}
local clients = {}

local status_path = vim.fn.tempname() .. ".json"
vim.fn.writefile({
  vim.json.encode({
    status = "ready",
    repl_ready = true,
    repl_seq = 3,
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
  bridge_env = function()
    return {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = status_path,
      ARK_SESSION_TMUX_SOCKET = "/tmp/ark.sock",
      ARK_SESSION_TMUX_SESSION = "project",
      ARK_SESSION_TMUX_PANE = "%42",
      ARK_SESSION_TIMEOUT_MS = "1000",
    }
  end,
  status = function()
    status_calls = status_calls + 1
    return {
      session = {
        tmux_socket = "/tmp/ark.sock",
        tmux_session = "project",
        tmux_pane = "%42",
      },
      startup_status_path = status_path,
      startup_status = {
        status = "ready",
        repl_ready = true,
        repl_seq = 3,
        port = 9999,
        auth_token = "token",
      },
      bridge_ready = true,
    }
  end,
  session = function()
    return {
      tmux_socket = "/tmp/ark.sock",
      tmux_session = "project",
      tmux_pane = "%42",
    }
  end,
  startup_status_path = function()
    return status_path
  end,
  startup_status_authoritative = function()
    return {
      status = "ready",
      repl_ready = true,
      repl_seq = 3,
      port = 9999,
      auth_token = "token",
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
      session_timeout_ms = 1000,
    },
  }

  local client_id = lsp.start_async(opts, bufnr)
  if client_id ~= 1 then
    error("expected start_async to return client id 1, got " .. vim.inspect(client_id), 0)
  end

  local settled = vim.wait(1500, function()
    return #notifications >= 1
  end, 20, false)
  if not settled then
    error("expected at least one session update notification", 0)
  end

  if status_calls ~= 0 then
    error("expected async startup session syncs to avoid tmux.status() entirely, got " .. tostring(status_calls), 0)
  end

  local last = notifications[#notifications]
  if last.method ~= "ark/updateSession" or last.payload.status ~= "ready" or last.payload.replReady ~= true then
    error("unexpected final session payload: " .. vim.inspect(last), 0)
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
