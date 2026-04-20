vim.opt.rtp:prepend(vim.fn.getcwd())

local test = require("tests.e2e.ark_test")

package.loaded["ark.lsp"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.dev"] = nil

local uv = vim.uv or vim.loop
local original_new_fs_event = uv and uv.new_fs_event or nil
if uv then
  uv.new_fs_event = nil
end

local status_dir = test.run_tmpdir() .. "/deferred-startup-bootstrap-poll"
local status_path = status_dir .. "/status.json"
vim.fn.mkdir(status_dir, "p")

local function write_status(payload)
  vim.fn.writefile({ vim.json.encode(payload) }, status_path)
end

local function read_status()
  local ok, lines = pcall(vim.fn.readfile, status_path)
  if not ok or type(lines) ~= "table" or #lines == 0 then
    return nil
  end

  local decoded_ok, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(payload) ~= "table" then
    return nil
  end

  return payload
end

write_status({
  status = "starting",
  repl_ready = false,
  repl_seq = 0,
})

package.loaded["ark.tmux"] = {
  bridge_env = function()
    return nil
  end,
  session = function()
    return {
      tmux_socket = "/tmp/ark-test.sock",
      tmux_session = "ark-test",
      tmux_pane = "%42",
    }
  end,
  startup_status_path = function()
    return status_path
  end,
  startup_status_authoritative = function()
    return read_status()
  end,
}

package.loaded["ark.dev"] = {
  ensure_current_detached_lsp_cmd = function(cmd)
    return vim.deepcopy(cmd)
  end,
  detached_lsp_build_fingerprint = function()
    return "test-build"
  end,
}

local lsp = require("ark.lsp")

local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(bufnr, status_dir .. "/poll-bootstrap.R")
vim.bo[bufnr].filetype = "r"

local bootstrap_calls = {}
local startup_ready = nil
local started = false

local client = {
  id = 78,
  name = "ark_lsp",
  initialized = true,
  config = nil,
  is_stopped = function()
    return false
  end,
  request_sync = function(self, method, params)
    if method == "ark/internal/bootstrapSession" then
      bootstrap_calls[#bootstrap_calls + 1] = vim.deepcopy(params)
      return {
        result = {
          hydrated = params.status == "ready" and params.replReady == true,
        },
      }, nil
    end

    return { result = {} }, nil
  end,
  notify = function() end,
}

local original_start = vim.lsp.start
local original_get_client_by_id = vim.lsp.get_client_by_id
local original_get_clients = vim.lsp.get_clients
local original_buf_is_attached = vim.lsp.buf_is_attached

vim.lsp.start = function(config, start_opts)
  started = true
  client.config = vim.deepcopy(config)
  return client.id
end

vim.lsp.get_client_by_id = function(client_id)
  if started and client_id == client.id then
    return client
  end
  return nil
end

vim.lsp.get_clients = function(filter)
  if not started then
    return {}
  end
  if type(filter) == "table" and filter.name and filter.name ~= client.name then
    return {}
  end
  return { client }
end

vim.lsp.buf_is_attached = function(candidate_bufnr, client_id)
  return started and candidate_bufnr == bufnr and client_id == client.id
end

lsp.set_startup_ready_callback(function(callback_bufnr, payload)
  startup_ready = {
    bufnr = callback_bufnr,
    payload = vim.deepcopy(payload),
  }
end)

local ok, err = pcall(function()
  local opts = {
    filetypes = { "r" },
    lsp = {
      name = "ark_lsp",
      cmd = { "ark-lsp", "--runtime-mode", "detached" },
      restart_wait_ms = 200,
      root_markers = {},
    },
    tmux = {
      bridge_wait_ms = 200,
      session_timeout_ms = 200,
      session_kind = "ark",
    },
  }

  local client_id = lsp.start(opts, bufnr)
  if client_id ~= client.id then
    test.fail("expected lsp.start() to return fake client id, got " .. vim.inspect(client_id))
  end

  if #bootstrap_calls ~= 1 then
    test.fail("expected initial bootstrap attempt during sync startup, got " .. vim.inspect(bootstrap_calls))
  end
  if bootstrap_calls[1].status ~= "starting" or bootstrap_calls[1].replReady ~= false then
    test.fail("expected initial bootstrap payload to be non-ready, got " .. vim.inspect(bootstrap_calls[1]))
  end

  write_status({
    status = "ready",
    repl_ready = true,
    repl_seq = 1,
  })

  test.wait_for("polled startup bootstrap", 2000, function()
    return #bootstrap_calls >= 2 and startup_ready ~= nil
  end)

  if bootstrap_calls[2].status ~= "ready" or bootstrap_calls[2].replReady ~= true then
    test.fail("expected polled bootstrap payload to become ready, got " .. vim.inspect(bootstrap_calls[2]))
  end

  if type(startup_ready) ~= "table" or startup_ready.bufnr ~= bufnr then
    test.fail("expected startup-ready callback for current buffer, got " .. vim.inspect(startup_ready))
  end
  if startup_ready.payload.source ~= "LspBootstrapPoll" then
    test.fail("expected poll bootstrap startup-ready source, got " .. vim.inspect(startup_ready))
  end
end)

vim.lsp.start = original_start
vim.lsp.get_client_by_id = original_get_client_by_id
vim.lsp.get_clients = original_get_clients
vim.lsp.buf_is_attached = original_buf_is_attached
if uv then
  uv.new_fs_event = original_new_fs_event
end
package.loaded["ark.lsp"] = nil

if not ok then
  error(err, 0)
end
