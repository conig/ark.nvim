vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
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
local clients = {}

local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_stop_client = vim.lsp.stop_client
local original_buf_is_attached = vim.lsp.buf_is_attached

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
    stop = function(self, force)
      stopped[#stopped + 1] = {
        id = self.id,
        force = force,
      }
      self._stopped = true
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
      and (not filter or not filter.name or client.name == filter.name)
      and (not filter or not filter.bufnr or client.attached_buffers[filter.bufnr] == true)
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

vim.lsp.buf_is_attached = function(bufnr, client_id)
  return clients[client_id] and clients[client_id].attached_buffers[bufnr] == true or false
end

vim.lsp.stop_client = function()
  error("deprecated vim.lsp.stop_client() should not be called", 0)
end

local ok, err = pcall(function()
  local lsp = require("ark.lsp")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_lsp_stop_uses_client_method.R")
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

  -- Regression: stale-client replacement and explicit restart must use client:stop().
  lsp.start(opts, buf, {
    wait_for_client = false,
  })

  lsp.start(opts, buf, {
    wait_for_client = false,
  })

  if #started ~= 2 then
    error("expected stale detached client replacement to trigger two starts, saw " .. #started, 0)
  end

  if not vim.deep_equal(stopped, {
    { id = 1, force = nil },
  }) then
    error("expected stale client replacement to stop client 1 via client:stop(), saw " .. vim.inspect(stopped), 0)
  end

  lsp.restart(opts, buf, {
    wait_for_client = false,
  })

  if #started ~= 3 then
    error("expected explicit restart to launch a third client, saw " .. #started, 0)
  end

  if not vim.deep_equal(stopped, {
    { id = 1, force = nil },
    { id = 2, force = nil },
  }) then
    error("expected restart to stop the current client via client:stop(), saw " .. vim.inspect(stopped), 0)
  end

  vim.api.nvim_buf_delete(buf, { force = true })
end)

vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.stop_client = original_stop_client
vim.lsp.buf_is_attached = original_buf_is_attached

if not ok then
  error(err, 0)
end
