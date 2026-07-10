vim.opt.rtp:prepend(vim.fn.getcwd())

local test = require("tests.e2e.ark_test")

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil
package.loaded["ark.session"] = nil

local status_path = test.run_tmpdir() .. "/inflight-bootstrap-status.json"
vim.fn.writefile({
  vim.json.encode({
    status = "ready",
    repl_ready = true,
    repl_seq = 4,
    port = 9999,
    auth_token = "token",
  }),
}, status_path)

local function session_snapshot()
  local status = {
    status = "ready",
    repl_ready = true,
    repl_seq = 4,
    port = 9999,
    auth_token = "token",
  }

  return {
    session = {
      tmux_socket = "/tmp/ark-test.sock",
      tmux_session = "ark-test",
      tmux_pane = "%42",
    },
    session_id = "inflight-bootstrap-session",
    status_path = status_path,
    startup_status_path = status_path,
    startup_status = vim.deepcopy(status),
    authoritative_status = vim.deepcopy(status),
    bridge_ready = true,
  }
end

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
    return session_snapshot().session
  end,
  session_id = function()
    return "inflight-bootstrap-session"
  end,
  startup_snapshot = session_snapshot,
  startup_status_path = function()
    return status_path
  end,
  startup_status_authoritative = function()
    return session_snapshot().authoritative_status
  end,
}

local notifications = {}
local bootstrap_callback = nil
local client = nil

local original_start = vim.lsp.start
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_get_clients = vim.lsp.get_clients
local original_buf_is_attached = vim.lsp.buf_is_attached
local original_stop_client = vim.lsp.stop_client

vim.lsp.start = function(config, start_opts)
  client = {
    id = 93,
    name = config.name,
    initialized = true,
    config = vim.deepcopy(config),
    attached_buffers = { [start_opts.bufnr] = true },
    is_stopped = function()
      return false
    end,
    notify = function(_, method, params)
      notifications[#notifications + 1] = {
        method = method,
        params = vim.deepcopy(params),
      }
    end,
    request = function(_, method, _, callback)
      if method ~= "ark/internal/bootstrapSession" then
        test.fail("unexpected request: " .. tostring(method))
      end
      bootstrap_callback = callback
      return true, 1
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
  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      restart_wait_ms = 1000,
      root_markers = {},
    },
    tmux = {
      bridge_wait_ms = 1000,
      session_timeout_ms = 1000,
      session_kind = "ark",
    },
  }

  -- Reproduce the runtime race: a ready-session bootstrap is still in flight
  -- when the status watch observes the same payload and tries to notify the
  -- server. A second delivery advances the session generation and makes a
  -- concurrent completion response stale.
  local client_id = lsp.start(opts, bufnr)
  if client_id ~= 93 or type(bootstrap_callback) ~= "function" then
    test.fail("expected one in-flight startup bootstrap")
  end

  lsp.sync_sessions(opts, bufnr)

  if #notifications ~= 0 then
    test.fail("in-flight bootstrap payload was delivered again: " .. vim.inspect(notifications))
  end

  bootstrap_callback(nil, { hydrated = true })
end)

vim.lsp.start = original_start
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.get_clients = original_get_clients
vim.lsp.buf_is_attached = original_buf_is_attached
vim.lsp.stop_client = original_stop_client
package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil
package.loaded["ark.session"] = nil

if not ok then
  error(err, 0)
end
