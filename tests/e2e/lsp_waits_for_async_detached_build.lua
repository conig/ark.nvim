vim.opt.rtp:prepend(vim.fn.getcwd())

local build_calls = 0
package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd, opts)
    build_calls = build_calls + 1
    if build_calls == 1 then
      vim.schedule(function()
        opts.on_build_complete({
          ok = true,
          binary_path = "/tmp/ark-lsp",
        })
      end)
      return nil, {
        kind = "build_pending",
        message = "Rebuilding detached ark-lsp...",
      }
    end

    return vim.deepcopy(cmd), nil
  end,
  detached_lsp_build_fingerprint = function(path)
    return path .. "::build"
  end,
}

package.loaded["ark.tmux"] = {
  bridge_env = function()
    return {}
  end,
}
package.loaded["ark.lsp"] = nil

local started = {}
local clients = {}
local notifications = {}

local original_notify = vim.notify
local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id

vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

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

local ok, err = pcall(function()
  local lsp = require("ark.lsp")

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_lsp_waits_for_async_detached_build.R")
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

  local built = vim.wait(1000, function()
    return #started == 1
  end, 20, false)

  if not built then
    error("expected async detached build retry to eventually start the LSP", 0)
  end

  if build_calls ~= 2 then
    error("expected detached build path to be rechecked after rebuild, saw " .. build_calls, 0)
  end

  if started[1].cmd[1] ~= "ark-lsp" then
    error("unexpected started config: " .. vim.inspect(started[1]), 0)
  end

  for _, entry in ipairs(notifications) do
    if entry.level == vim.log.levels.ERROR then
      error("unexpected error notification during async detached build: " .. vim.inspect(notifications), 0)
    end
  end

  vim.api.nvim_buf_delete(buf, { force = true })
end)

vim.notify = original_notify
vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id

if not ok then
  error(err, 0)
end
