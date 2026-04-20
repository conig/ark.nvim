vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil

local notifications = {}
local status_calls = 0
local session_calls = 0
local startup_status_calls = 0
local authoritative_calls = 0

package.loaded["ark.tmux"] = {
  status = function()
    status_calls = status_calls + 1
    error("fast session sync should not call tmux.status()", 0)
  end,
  session = function()
    session_calls = session_calls + 1
    return {
      tmux_socket = "/tmp/ark.sock",
      tmux_session = "project",
      tmux_pane = "%42",
    }
  end,
  session_id = function()
    return "tmux-session-42"
  end,
  startup_status = function()
    startup_status_calls = startup_status_calls + 1
    return {
      status = "ready",
      repl_ready = true,
      repl_seq = 7,
    }
  end,
  startup_status_authoritative = function()
    authoritative_calls = authoritative_calls + 1
    return {
      status = "ready",
      repl_ready = true,
      repl_seq = 7,
    }
  end,
  startup_status_path = function()
    return "/tmp/ark-status/mock.json"
  end,
}

local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "r"

local client = {
  id = 1,
  initialized = true,
  name = "ark_lsp",
  attached_buffers = { [bufnr] = true },
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

local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_is_attached = vim.lsp.buf_is_attached

vim.lsp.get_clients = function(filter)
  if filter and filter.name and filter.name ~= client.name then
    return {}
  end
  if filter and filter.bufnr and filter.bufnr ~= bufnr then
    return {}
  end
  return { client }
end

vim.lsp.get_client_by_id = function(id)
  if id == client.id then
    return client
  end
  return nil
end

vim.lsp.buf_is_attached = function(buffer, id)
  return buffer == bufnr and id == client.id
end

local ok, err = pcall(function()
  local lsp = require("ark.lsp")
  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
    },
    tmux = {
      session_kind = "ark",
      session_timeout_ms = 1000,
    },
  }

  lsp.sync_sessions(opts, nil, { fast = true })

  if status_calls ~= 0 then
    error("expected fast sync to avoid tmux.status(), got " .. tostring(status_calls), 0)
  end
  if startup_status_calls ~= 0 then
    error("expected fast sync to avoid tmux.startup_status(), got " .. tostring(startup_status_calls), 0)
  end
  if session_calls ~= 1 then
    error("expected fast sync to resolve tmux session once, got " .. tostring(session_calls), 0)
  end
  if authoritative_calls ~= 1 then
    error("expected fast sync to read authoritative startup state once, got " .. tostring(authoritative_calls), 0)
  end
  if #notifications ~= 1 then
    error("expected one session update notification, got " .. vim.inspect(notifications), 0)
  end

  local update = notifications[1]
  if update.method ~= "ark/updateSession" then
    error("expected ark/updateSession notification, got " .. vim.inspect(update), 0)
  end

  local payload = update.payload
  if payload.backend ~= "tmux"
    or payload.sessionId ~= "tmux-session-42"
    or payload.tmuxSocket ~= "/tmp/ark.sock"
    or payload.tmuxSession ~= "project"
    or payload.tmuxPane ~= "%42"
    or payload.statusFile ~= "/tmp/ark-status/mock.json"
    or payload.status ~= "ready"
    or payload.replReady ~= true
    or payload.replSeq ~= 7
  then
    error("unexpected fast session payload: " .. vim.inspect(payload), 0)
  end
end)

vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_is_attached = original_buf_is_attached

if not ok then
  error(err, 0)
end
