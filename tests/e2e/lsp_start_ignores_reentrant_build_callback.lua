vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local captured_build_callback = nil
local build_callback_fired = false
local request_depth = 0
local max_request_depth = 0
local bootstrap_requests = {}
local clients = {}

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
  ensure_current_detached_lsp_cmd = function(cmd, opts)
    captured_build_callback = opts and opts.on_build_complete or nil
    return vim.deepcopy(cmd), nil
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

package.loaded["ark.tmux"] = {
  session_id = function()
    return "tmux-session-42"
  end,
  startup_snapshot = function()
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
      bridge_ready = true,
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
    notify = function() end,
    request_sync = function(_, method, payload, timeout_ms, bufnr)
      request_depth = request_depth + 1
      max_request_depth = math.max(max_request_depth, request_depth)
      bootstrap_requests[#bootstrap_requests + 1] = {
        method = method,
        payload = vim.deepcopy(payload),
        timeout_ms = timeout_ms,
        bufnr = bufnr,
      }

      -- Regression: Neovim's request_sync() waits with scheduled callbacks
      -- enabled. A detached build completion that fires during this wait must
      -- not recursively re-enter start_client() and bootstrap the same client.
      if not build_callback_fired and type(captured_build_callback) == "function" then
        build_callback_fired = true
        captured_build_callback({ ok = true })
        vim.wait(100, function()
          return #bootstrap_requests > 1
        end, 10, false)
      end

      request_depth = request_depth - 1
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
  local client_id = lsp.start({
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
  }, bufnr)

  if client_id ~= 1 then
    error("expected lsp.start to return client id 1, got " .. vim.inspect(client_id), 0)
  end
  if not build_callback_fired then
    error("expected test to fire detached build callback during bootstrap", 0)
  end
  if #bootstrap_requests ~= 1 then
    error("expected one bootstrap request, got " .. vim.inspect(bootstrap_requests), 0)
  end
  if max_request_depth ~= 1 then
    error("expected no re-entrant bootstrap request, got depth " .. tostring(max_request_depth), 0)
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
