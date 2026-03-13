vim.opt.rtp:prepend(vim.fn.getcwd())

local status_dir = vim.fn.tempname()
vim.fn.mkdir(status_dir, "p")

local status_path = status_dir .. "/session.json"
local current_status = {
  status = "pending",
}

vim.fn.writefile({ vim.json.encode(current_status) }, status_path)

package.loaded["ark.tmux"] = {
  bridge_env = function()
    if current_status.status ~= "ready" then
      return nil
    end

    return {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_HOST = "127.0.0.1",
      ARK_SESSION_PORT = tostring(current_status.port),
      ARK_SESSION_AUTH_TOKEN = current_status.auth_token or "",
      ARK_SESSION_TMUX_SOCKET = "/tmp/ark-test.sock",
      ARK_SESSION_TMUX_SESSION = "ark-test",
      ARK_SESSION_TMUX_PANE = "%1",
      ARK_SESSION_TIMEOUT_MS = "1000",
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

local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_stop_client = vim.lsp.stop_client

vim.lsp.start = function(config, _)
  started[#started + 1] = vim.deepcopy(config)
  return #started
end

vim.lsp.get_clients = function(_)
  return {}
end

vim.lsp.get_client_by_id = function(_)
  return nil
end

vim.lsp.stop_client = function(client_id)
  stopped[#stopped + 1] = client_id
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
  if started_early then
    error("async startup launched LSP before bridge readiness was published", 0)
  end

  vim.defer_fn(function()
    current_status = {
      status = "ready",
      port = 43123,
      auth_token = "ark-test-token",
    }
    vim.fn.writefile({ vim.json.encode(current_status) }, status_path)
  end, 150)

  local ready_ok = vim.wait(1200, function()
    return #started == 1
  end, 10, false)
  if not ready_ok then
    error("timed out waiting for the live LSP start", 0)
  end

  if #started ~= 1 then
    error("expected exactly one LSP start after bridge readiness, saw " .. #started, 0)
  end

  if #stopped ~= 0 then
    error("expected no stop/start churn during async startup, saw " .. #stopped .. " stops", 0)
  end

  local cmd_env = started[1].cmd_env or {}
  if cmd_env.ARK_SESSION_PORT ~= "43123" then
    error("expected live bridge env on first LSP start, got " .. vim.inspect(cmd_env), 0)
  end

  vim.print({
    starts = #started,
    live_port = cmd_env.ARK_SESSION_PORT,
  })
end)

vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.stop_client = original_stop_client

if not ok then
  error(err, 0)
end
