vim.opt.rtp:prepend(vim.fn.getcwd())

local status_dir = vim.fn.tempname()
vim.fn.mkdir(status_dir, "p")

local status_path = status_dir .. "/session.json"
local current_status = {
  status = "ready",
  repl_ready = true,
  port = 43123,
  auth_token = "token-one",
}

vim.fn.writefile({ vim.json.encode(current_status) }, status_path)

package.loaded["ark.tmux"] = {
  bridge_env = function()
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
  startup_status = function()
    return vim.deepcopy(current_status)
  end,
  startup_status_path = function()
    return status_path
  end,
}
package.loaded["ark.lsp"] = nil

local started = {}
local stopped = {}
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
    notify = function() end,
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
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_bridge_auth_token_refresh.R")
  vim.bo[buf].filetype = "r"

  lsp.start({
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
  }, buf, {
    wait_for_client = false,
  })

  if #started ~= 1 then
    error("expected initial detached LSP start, saw " .. #started, 0)
  end

  vim.defer_fn(function()
    current_status.auth_token = "token-two"
    vim.fn.writefile({ vim.json.encode(current_status) }, status_path)
  end, 100)

  vim.wait(400, function()
    return false
  end, 50, false)

  if #started ~= 1 then
    error("expected auth token rotation to avoid client restart, saw starts=" .. #started, 0)
  end

  if #stopped ~= 0 then
    error("expected auth token rotation to avoid client stop/start churn, saw stops=" .. vim.inspect(stopped), 0)
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
