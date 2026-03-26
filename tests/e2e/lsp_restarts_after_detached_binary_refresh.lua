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
  }

  started[#started + 1] = vim.deepcopy(config)
  clients[id] = client
  return id
end

vim.lsp.get_clients = function(filter)
  local out = {}
  for _, client in pairs(clients) do
    if not client._stopped then
      local matches_name = not filter or not filter.name or client.config.name == filter.name
      if matches_name then
        out[#out + 1] = client
      end
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
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_lsp_restarts_after_detached_binary_refresh.R")
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

  lsp.start(opts, buf, {
    wait_for_client = false,
  })

  lsp.start(opts, buf, {
    wait_for_client = false,
  })

  if #started ~= 2 then
    error("expected rebuilt detached binary to trigger a second LSP start, saw " .. #started, 0)
  end

  if not vim.deep_equal(stopped, { 1 }) then
    error("expected stale client to be stopped before restart, saw " .. vim.inspect(stopped), 0)
  end

  if started[1]._ark_lsp_build_fingerprint ~= "ark-lsp::build1" then
    error("unexpected initial fingerprint: " .. vim.inspect(started[1]), 0)
  end

  if started[2]._ark_lsp_build_fingerprint ~= "ark-lsp::build2" then
    error("unexpected rebuilt fingerprint: " .. vim.inspect(started[2]), 0)
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
