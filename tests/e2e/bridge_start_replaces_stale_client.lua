vim.opt.rtp:prepend(vim.fn.getcwd())

local current_session = {
  tmux_socket = "/tmp/ark-test.sock",
  tmux_session = "ark-test",
  tmux_pane = "%1",
}

local status_dir = vim.fn.tempname()
vim.fn.mkdir(status_dir, "p")

local function status_path()
  return string.format("%s/%s.json", status_dir, current_session.tmux_pane:gsub("[^%w]", "_"))
end

local current_status = {
  status = "ready",
  repl_ready = true,
}

vim.fn.writefile({ vim.json.encode(current_status) }, status_path())

package.loaded["ark.tmux"] = {
  bridge_env = function()
    return {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = status_path(),
      ARK_SESSION_TMUX_SOCKET = current_session.tmux_socket,
      ARK_SESSION_TMUX_SESSION = current_session.tmux_session,
      ARK_SESSION_TMUX_PANE = current_session.tmux_pane,
      ARK_SESSION_TIMEOUT_MS = "1000",
    }
  end,
  session = function()
    return vim.deepcopy(current_session)
  end,
  startup_status = function()
    return vim.deepcopy(current_status)
  end,
  startup_status_path = function()
    return status_path()
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
  table.sort(out, function(lhs, rhs)
    return lhs.id < rhs.id
  end)
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
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_bridge_session_update.R")
  vim.bo[buf].filetype = "r"

  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      root_markers = { ".git" },
      restart_wait_ms = 0,
    },
    tmux = {
      bridge_wait_ms = 1000,
      session_kind = "ark",
      session_timeout_ms = 1000,
    },
  }

  lsp.start(opts, buf, {
    wait_for_client = false,
  })

  local notified_initial = vim.wait(1000, function()
    return #notifications > 0
  end, 10, false)
  if not notified_initial then
    error("expected initial session notification", 0)
  end

  current_session.tmux_pane = "%2"
  vim.fn.writefile({ vim.json.encode(current_status) }, status_path())

  lsp.sync_sessions(opts, buf)

  local updated = vim.wait(1000, function()
    local last = notifications[#notifications]
    return last
      and last.method == "ark/updateSession"
      and last.params
      and last.params.tmuxPane == "%2"
  end, 10, false)
  if not updated then
    error("expected in-place session update notification for pane change: " .. vim.inspect(notifications), 0)
  end

  if #started ~= 1 then
    error("expected exactly one LSP start, saw " .. #started, 0)
  end

  if #stopped ~= 0 then
    error("expected no client restart for session identity change, saw " .. vim.inspect(stopped), 0)
  end

  vim.api.nvim_buf_delete(buf, { force = true })
end)

vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.stop_client = original_stop_client

if not ok then
  error(err, 0)
end
