vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local watcher_starts = {}
local status_a_dir = vim.fn.tempname()
local status_b_dir = vim.fn.tempname()
vim.fn.mkdir(status_a_dir, "p")
vim.fn.mkdir(status_b_dir, "p")

local status_path_a = status_a_dir .. "/session.json"
local status_path_b = status_b_dir .. "/session.json"

local snapshots = {
  a = {
    session = {
      tmux_socket = "/tmp/a.sock",
      tmux_session = "session-a",
      tmux_pane = "%1",
    },
    status_path = status_path_a,
    startup_status_path = status_path_a,
    startup_status = {
      status = "pending",
      repl_ready = false,
      repl_seq = 1,
    },
    authoritative_status = {
      status = "pending",
      repl_ready = false,
      repl_seq = 1,
    },
    bridge_ready = false,
    cmd_env = {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = status_path_a,
      ARK_SESSION_TMUX_SOCKET = "/tmp/a.sock",
      ARK_SESSION_TMUX_SESSION = "session-a",
      ARK_SESSION_TMUX_PANE = "%1",
      ARK_SESSION_TIMEOUT_MS = "1000",
    },
  },
  b = {
    session = {
      tmux_socket = "/tmp/b.sock",
      tmux_session = "session-b",
      tmux_pane = "%2",
    },
    status_path = status_path_b,
    startup_status_path = status_path_b,
    startup_status = {
      status = "pending",
      repl_ready = false,
      repl_seq = 2,
    },
    authoritative_status = {
      status = "pending",
      repl_ready = false,
      repl_seq = 2,
    },
    bridge_ready = false,
    cmd_env = {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = status_path_b,
      ARK_SESSION_TMUX_SOCKET = "/tmp/b.sock",
      ARK_SESSION_TMUX_SESSION = "session-b",
      ARK_SESSION_TMUX_PANE = "%2",
      ARK_SESSION_TIMEOUT_MS = "1000",
    },
  },
}

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
    return cmd, nil
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

package.loaded["ark.tmux"] = {
  startup_snapshot = function(config)
    return vim.deepcopy(snapshots[config.test_session])
  end,
  bridge_env = function(config)
    local snapshot = snapshots[config.test_session]
    return snapshot and vim.deepcopy(snapshot.cmd_env) or {}
  end,
}

local original_new_fs_event = vim.uv.new_fs_event
local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_is_attached = vim.lsp.buf_is_attached
local original_stop_client = vim.lsp.stop_client

local fs_watchers = {}
local clients = {}
local next_client_id = 0
local notifications = {}

vim.uv.new_fs_event = function()
  local watcher = {
    started_path = nil,
    callback = nil,
    start = function(self, path, _, callback)
      self.started_path = path
      self.callback = callback
      watcher_starts[#watcher_starts + 1] = path
      fs_watchers[#fs_watchers + 1] = self
      return true
    end,
    stop = function() end,
    close = function() end,
  }
  return watcher
end

vim.lsp.start = function(config, opts)
  next_client_id = next_client_id + 1
  local id = next_client_id
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
        client_id = id,
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
      and (not filter or filter._uninitialized == true or client.initialized == true)
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
  local lsp = require("ark.lsp")

  local function new_buf(name)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].filetype = "r"
    return buf
  end

  local buf_a1 = new_buf("/tmp/lsp_session_watch_a1.R")
  local buf_a2 = new_buf("/tmp/lsp_session_watch_a2.R")
  local buf_b1 = new_buf("/tmp/lsp_session_watch_b1.R")

  local opts_a = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      root_markers = { ".git" },
      restart_wait_ms = 0,
    },
    tmux = {
      test_session = "a",
      bridge_wait_ms = 1000,
      session_timeout_ms = 1000,
    },
  }
  local opts_b = vim.deepcopy(opts_a)
  opts_b.tmux.test_session = "b"

  lsp.start_async(opts_a, buf_a1)
  lsp.start_async(opts_a, buf_a2)
  lsp.start_async(opts_b, buf_b1)

  local watchers_ready = vim.wait(1000, function()
    return #watcher_starts == 2
  end, 20, false)
  if not watchers_ready then
    error("expected one watcher per status file, got " .. vim.inspect(watcher_starts), 0)
  end

  notifications = {}
  snapshots.a.startup_status.status = "ready"
  snapshots.a.startup_status.repl_ready = true
  snapshots.a.authoritative_status.status = "ready"
  snapshots.a.authoritative_status.repl_ready = true
  snapshots.a.bridge_ready = true

  local watcher_a
  for _, watcher in ipairs(fs_watchers) do
    if watcher.started_path == status_a_dir then
      watcher_a = watcher
      break
    end
  end
  if not watcher_a or type(watcher_a.callback) ~= "function" then
    error("missing watcher for status file A", 0)
  end

  watcher_a.callback()

  local notified = vim.wait(1000, function()
    local seen = {}
    for _, entry in ipairs(notifications) do
      if entry.method == "ark/updateSession"
        and entry.payload
        and entry.payload.status == "ready"
        and entry.payload.replReady == true
      then
        seen[entry.client_id] = true
      end
    end
    return seen[1] == true and seen[2] == true
  end, 20, false)
  if not notified then
    error("timed out waiting for status file A notifications: " .. vim.inspect(notifications), 0)
  end

  for _, entry in ipairs(notifications) do
    if entry.client_id == 3
      and entry.method == "ark/updateSession"
      and entry.payload
      and entry.payload.status == "ready"
    then
      error("status file A update leaked to unrelated watcher: " .. vim.inspect(notifications), 0)
    end
  end
end)

vim.uv.new_fs_event = original_new_fs_event
vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_is_attached = original_buf_is_attached
vim.lsp.stop_client = original_stop_client

if not ok then
  error(err, 0)
end
