vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.bridge"] = nil

local runtime_root = vim.fn.tempname()
local installed_dir = runtime_root .. "/arkbridge"
local stamp_path = runtime_root .. "/.arkbridge-install.json"

vim.fn.mkdir(installed_dir, "p")
vim.fn.writefile({
  vim.json.encode({
    source_mtime = 1,
    runtime_revision = 2,
  }),
}, stamp_path)

local deferred = {}
local rg_calls = 0
local jobstart_calls = 0
local callbacks = {}

local original_defer_fn = vim.defer_fn
local original_executable = vim.fn.executable
local original_jobstart = vim.fn.jobstart
local original_schedule = vim.schedule
local original_systemlist = vim.fn.systemlist

vim.defer_fn = function(fn, timeout_ms)
  deferred[#deferred + 1] = {
    fn = fn,
    timeout_ms = timeout_ms,
  }
  return #deferred
end

vim.fn.executable = function(cmd)
  if cmd == "rg" then
    return 1
  end

  return original_executable(cmd)
end

vim.fn.jobstart = function(cmd, opts)
  jobstart_calls = jobstart_calls + 1

  if type(cmd) ~= "table" then
    error("expected bridge install job command table", 0)
  end

  local source_mtime = tonumber(cmd[#cmd - 1])
  if type(source_mtime) ~= "number" or source_mtime <= 1 then
    error("expected bridge install job to receive fresh source mtime, got " .. vim.inspect(cmd), 0)
  end

  vim.fn.writefile({
    vim.json.encode({
      source_mtime = source_mtime,
      runtime_revision = tonumber(cmd[#cmd]) or 0,
    }),
  }, stamp_path)

  if type(opts) == "table" and type(opts.on_exit) == "function" then
    opts.on_exit(1, 0)
  end

  return 1
end

vim.schedule = function(fn)
  fn()
end

vim.fn.systemlist = function(cmd)
  if type(cmd) == "table" and cmd[1] == "rg" then
    rg_calls = rg_calls + 1
  end

  return original_systemlist(cmd)
end

local ok, err = pcall(function()
  local bridge = require("ark.bridge")
  local config = {
    session_lib_path = runtime_root,
    session_pkg_path = vim.fn.getcwd() .. "/packages/arkbridge",
  }
  local opts = {
    on_build_complete = function(result)
      callbacks[#callbacks + 1] = result
    end,
  }

  local ready_one, err_one = bridge.ensure_current_runtime(config, opts)
  local ready_two, err_two = bridge.ensure_current_runtime(config, opts)

  if ready_one ~= true or ready_two ~= true or err_one ~= nil or err_two ~= nil then
    error("expected existing bridge runtime to return immediately: " .. vim.inspect({
      ready_one = ready_one,
      ready_two = ready_two,
      err_one = err_one,
      err_two = err_two,
    }), 0)
  end
  if rg_calls ~= 0 then
    error("expected no bridge source scan on the startup path, got " .. tostring(rg_calls), 0)
  end
  if #deferred ~= 1 then
    error("expected one deferred bridge freshness probe, got " .. tostring(#deferred), 0)
  end
  if deferred[1].timeout_ms ~= 250 then
    error("expected deferred bridge freshness probe to wait 250ms, got " .. tostring(deferred[1].timeout_ms), 0)
  end

  deferred[1].fn()

  if rg_calls == 0 then
    error("expected deferred bridge freshness probe to scan sources", 0)
  end
  if jobstart_calls ~= 1 then
    error("expected stale existing bridge runtime to start one background install, got " .. tostring(jobstart_calls), 0)
  end
  if #callbacks ~= 1 or callbacks[1].ok ~= true then
    error("expected deferred bridge install to notify build completion listener: " .. vim.inspect(callbacks), 0)
  end
end)

vim.defer_fn = original_defer_fn
vim.fn.executable = original_executable
vim.fn.jobstart = original_jobstart
vim.schedule = original_schedule
vim.fn.systemlist = original_systemlist
vim.fn.delete(runtime_root, "rf")

if not ok then
  error(err, 0)
end
