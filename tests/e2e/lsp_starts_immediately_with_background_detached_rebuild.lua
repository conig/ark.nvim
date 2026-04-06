vim.opt.rtp:prepend(vim.fn.getcwd())

local ensure_calls = 0
package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd, opts)
    ensure_calls = ensure_calls + 1
    if ensure_calls == 1 then
      vim.defer_fn(function()
        opts.on_build_complete({
          ok = true,
          binary_path = "/tmp/ark-lsp",
        })
      end, 120)
    end

    return vim.deepcopy(cmd), nil
  end,
}

local fingerprint_calls = 0
package.loaded["ark.dev"].detached_lsp_build_fingerprint = function(path)
  if path ~= "ark-lsp" then
    return nil
  end

  fingerprint_calls = fingerprint_calls + 1
  if fingerprint_calls == 1 then
    return "ark-lsp::build1"
  end

  return "ark-lsp::build2"
end

package.loaded["ark.tmux"] = {
  bridge_env = function()
    return {}
  end,
}
package.loaded["ark.lsp"] = nil

local started = {}
local stopped = {}
local notifications = {}
local clients = {}

local original_notify = vim.notify
local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_stop_client = vim.lsp.stop_client
local original_buf_is_attached = vim.lsp.buf_is_attached

vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

vim.lsp.start = function(config, opts)
  local id = #started + 1
  local client = {
    id = id,
    name = config.name,
    config = vim.deepcopy(config),
    initialized = true,
    attached_buffers = { [opts.bufnr] = true },
    _stopped = false,
    is_stopped = function(self)
      return self._stopped == true
    end,
  }

  started[#started + 1] = vim.deepcopy(config)
  clients[id] = client
  return id
end

vim.lsp.get_clients = function(filter)
  local out = {}
  for _, client in pairs(clients) do
    if not client._stopped
      and (not filter or not filter.name or filter.name == client.name)
      and (not filter or not filter.bufnr or client.attached_buffers[filter.bufnr])
    then
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

vim.lsp.buf_is_attached = function(bufnr, client_id)
  return clients[client_id] and clients[client_id].attached_buffers[bufnr] == true or false
end

local ok, err = pcall(function()
  local lsp = require("ark.lsp")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_lsp_starts_immediately_with_background_detached_rebuild.R")
  vim.bo[buf].filetype = "r"

  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      root_markers = { ".git" },
      restart_wait_ms = 0,
    },
    tmux = {},
  }

  local client_id = lsp.start_async(opts, buf)
  if client_id ~= 1 then
    error("expected immediate client start with id 1, got " .. vim.inspect(client_id), 0)
  end

  local started_early = vim.wait(80, function()
    return #started == 1
  end, 10, false)
  if not started_early then
    error("expected stale-but-usable detached binary to start immediately", 0)
  end

  if #stopped ~= 0 then
    error("unexpected early stop before background rebuild completed: " .. vim.inspect(stopped), 0)
  end

  local rebuilt = vim.wait(1000, function()
    return #started == 2
  end, 20, false)
  if not rebuilt then
    error("expected background detached rebuild to trigger a controlled restart", 0)
  end

  if not vim.deep_equal(stopped, { 1 }) then
    error("expected exactly one stale client stop during restart, saw " .. vim.inspect(stopped), 0)
  end

  if started[1]._ark_lsp_build_fingerprint ~= "ark-lsp::build1" then
    error("unexpected initial fingerprint: " .. vim.inspect(started[1]), 0)
  end

  if started[2]._ark_lsp_build_fingerprint ~= "ark-lsp::build2" then
    error("unexpected rebuilt fingerprint: " .. vim.inspect(started[2]), 0)
  end

  for _, entry in ipairs(notifications) do
    if entry.level == vim.log.levels.ERROR then
      error("unexpected error notification during background detached rebuild: " .. vim.inspect(notifications), 0)
    end
  end

  vim.api.nvim_buf_delete(buf, { force = true })
end)

vim.notify = original_notify
vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.stop_client = original_stop_client
vim.lsp.buf_is_attached = original_buf_is_attached

if not ok then
  error(err, 0)
end
