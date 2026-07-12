vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
    return vim.deepcopy(cmd), nil
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

local notices = {}
local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notices[#notices + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end

package.loaded["ark.notifications"] = nil
package.loaded["ark.lsp_recovery"] = nil
package.loaded["ark.lsp"] = nil

local clients = {}
local started = {}
local stopped = {}
local deferred = {}

local original_start = vim.lsp.start
local original_get_clients = vim.lsp.get_clients
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_buf_is_attached = vim.lsp.buf_is_attached
local original_stop_client = vim.lsp.stop_client
local original_defer_fn = vim.defer_fn

vim.defer_fn = function(callback, delay_ms)
  deferred[#deferred + 1] = {
    callback = callback,
    delay_ms = delay_ms,
  }
end

vim.lsp.start = function(config, start_opts)
  local client_id = #started + 1
  local client = {
    id = client_id,
    name = config.name,
    config = vim.deepcopy(config),
    initialized = true,
    attached_buffers = { [start_opts.bufnr] = true },
    _stopped = false,
    is_stopped = function(self)
      return self._stopped
    end,
    stop = function(self, force)
      stopped[#stopped + 1] = {
        id = self.id,
        force = force,
      }
      self._stopped = true
    end,
  }

  clients[client_id] = client
  started[client_id] = config
  return client_id
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

vim.lsp.get_client_by_id = function(client_id)
  return clients[client_id]
end

vim.lsp.buf_is_attached = function(bufnr, client_id)
  return clients[client_id] and clients[client_id].attached_buffers[bufnr] == true or false
end

vim.lsp.stop_client = function()
  error("expected ark.nvim to use client:stop()", 0)
end

local function exit_client(client_id, code, signal)
  clients[client_id]._stopped = true
  local on_exit = started[client_id].on_exit
  if type(on_exit) ~= "function" then
    error("expected ark.nvim to configure an LSP on_exit recovery handler", 0)
  end
  on_exit(code, signal, client_id)
end

local function exit_unexpectedly(client_id)
  exit_client(client_id, 1, 0)
end

local ok, err = pcall(function()
  local lsp = require("ark.lsp")
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/ark_lsp_recovers_from_unexpected_exit.R")
  vim.bo[bufnr].filetype = "r"

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
  local start_opts = {
    wait_for_client = false,
    background_session_updates = false,
  }

  if lsp.start(opts, bufnr, start_opts) ~= 1 then
    error("expected the initial client id to be 1", 0)
  end

  -- An explicit restart is intentional. Its eventual exit callback must not
  -- schedule a second, surprise restart.
  if lsp.restart(opts, bufnr, start_opts) ~= 2 then
    error("expected explicit restart to launch client 2", 0)
  end
  started[1].on_exit(0, 15, 1)
  if #deferred ~= 0 then
    error("intentional client shutdown scheduled crash recovery", 0)
  end

  -- Unexpected exits restart with bounded exponential backoff.
  local expected_delays = { 250, 500, 1000 }
  for index, expected_delay in ipairs(expected_delays) do
    local client_id = index + 1
    exit_unexpectedly(client_id)

    vim.wait(100, function()
      return #deferred >= index
    end, 1, false)

    local pending = deferred[index]
    if not pending or pending.delay_ms ~= expected_delay then
      error(string.format(
        "expected crash %d to schedule %d ms recovery, got %s",
        index,
        expected_delay,
        vim.inspect(pending)
      ), 0)
    end

    pending.callback()
    if #started ~= client_id + 1 then
      error("scheduled recovery did not launch the next client", 0)
    end
  end

  -- A fourth crash in the same window is a crash loop. Stop retrying and make
  -- the failure visible instead of spinning forever.
  exit_unexpectedly(5)
  vim.wait(100, function()
    return #notices >= 2
  end, 1, false)
  if #deferred ~= 3 then
    error("crash-loop guard scheduled more than three recovery attempts", 0)
  end
  if #notices ~= 2 or notices[#notices].level ~= vim.log.levels.ERROR then
    error("expected exhausted recovery to emit a visible error", 0)
  end

  -- Manual recovery starts a new episode. Its warning must be visible even
  -- though ark.notifications deduplicates warning keys within one episode.
  if lsp.restart(opts, bufnr, start_opts) ~= 6 then
    error("expected manual recovery to launch client 6", 0)
  end
  exit_unexpectedly(6)
  vim.wait(100, function()
    return #deferred >= 4 and #notices >= 3
  end, 1, false)
  if not deferred[4] or deferred[4].delay_ms ~= 250 then
    error("new recovery episode did not reset exponential backoff", 0)
  end
  if #notices ~= 3 or notices[3].level ~= vim.log.levels.WARN then
    error("new recovery episode warning was hidden by notification deduplication", 0)
  end

  -- An explicit restart cancels already-scheduled recovery. A clean process
  -- exit still recovers: ark-lsp deliberately shuts down with status 0 after
  -- containing an internal handler panic.
  if lsp.restart(opts, bufnr, start_opts) ~= 7 then
    error("expected explicit restart to launch client 7", 0)
  end
  deferred[4].callback()
  if #started ~= 7 then
    error("cancelled crash recovery launched a duplicate client", 0)
  end
  exit_client(7, 0, 0)
  vim.wait(100, function()
    return #deferred >= 5 and #notices >= 4
  end, 1, false)
  if not deferred[5] or deferred[5].delay_ms ~= 250 then
    error("clean unexpected exit did not schedule recovery", 0)
  end
  deferred[5].callback()
  if #started ~= 8 then
    error("clean unexpected exit did not relaunch ark-lsp", 0)
  end

  opts.lsp.crash_recovery = { enabled = false }
  if lsp.restart(opts, bufnr, start_opts) ~= 9 then
    error("expected recovery-disabled restart to launch client 9", 0)
  end
  started[8].on_exit(0, 15, 8)
  exit_unexpectedly(9)
  vim.wait(20)
  if #deferred ~= 5 then
    error("disabled crash recovery scheduled a restart", 0)
  end

  if not vim.deep_equal(stopped, {
    { id = 1, force = nil },
    { id = 8, force = nil },
  }) then
    error("unexpected client stop calls: " .. vim.inspect(stopped), 0)
  end

  vim.api.nvim_buf_delete(bufnr, { force = true })
end)

vim.lsp.start = original_start
vim.lsp.get_clients = original_get_clients
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.buf_is_attached = original_buf_is_attached
vim.lsp.stop_client = original_stop_client
vim.defer_fn = original_defer_fn
vim.notify = original_notify

if not ok then
  error(err, 0)
end
