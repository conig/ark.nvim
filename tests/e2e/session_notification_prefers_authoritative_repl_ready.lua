vim.opt.rtp:prepend(vim.fn.getcwd())

local current_session = {
  tmux_socket = "/tmp/ark-test.sock",
  tmux_session = "ark-test",
  tmux_pane = "%1",
}

local ui_status = {
  status = "ready",
  repl_ready = true,
}

local authoritative_status = {
  status = "ready",
  repl_ready = false,
}

package.loaded["ark.tmux"] = {
  bridge_env = function()
    return {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = "/tmp/ark-test-status.json",
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
    return vim.deepcopy(ui_status)
  end,
  startup_status_authoritative = function()
    return vim.deepcopy(authoritative_status)
  end,
  startup_status_path = function()
    return "/tmp/ark-test-status.json"
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
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_authoritative_repl_ready.R")
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

  local initial_ok = vim.wait(1000, function()
    local first = notifications[1]
    return first
      and first.method == "ark/updateSession"
      and first.params
      and first.params.status == "ready"
  end, 10, false)
  if not initial_ok then
    error("expected initial ready session notification", 0)
  end

  if notifications[1].params.replReady ~= false then
    error(
      "expected authoritative status file to keep replReady false until it flips: "
        .. vim.inspect(notifications),
      0
    )
  end

  authoritative_status.repl_ready = true
  lsp.sync_sessions(opts, buf)

  local ready_ok = vim.wait(1000, function()
    local last = notifications[#notifications]
    return last
      and last.method == "ark/updateSession"
      and last.params
      and last.params.replReady == true
  end, 10, false)
  if not ready_ok then
    error("expected replReady=true after authoritative status updated: " .. vim.inspect(notifications), 0)
  end

  if #started ~= 1 then
    error("expected exactly one LSP start, saw " .. #started, 0)
  end

  if #stopped ~= 0 then
    error("expected no client restart while session readiness changes, saw " .. vim.inspect(stopped), 0)
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
