vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.bridge"] = nil

local runtime_root = vim.fn.tempname()
local installed_dir = runtime_root .. "/arkbridge"
local stamp_path = runtime_root .. "/.arkbridge-install.json"

vim.fn.mkdir(installed_dir, "p")
vim.fn.writefile({
  vim.json.encode({
    source_mtime = 999999999,
  }),
}, stamp_path)

local deferred = {}
local jobstart_calls = {}
local callbacks = {}

local original_defer_fn = vim.defer_fn
local original_executable = vim.fn.executable
local original_jobstart = vim.fn.jobstart
local original_schedule = vim.schedule

vim.defer_fn = function(fn, timeout_ms)
  deferred[#deferred + 1] = {
    fn = fn,
    timeout_ms = timeout_ms,
  }
  return #deferred
end

vim.fn.executable = function(cmd)
  if cmd == "R" then
    return 1
  end

  return original_executable(cmd)
end

vim.fn.jobstart = function(cmd, opts)
  jobstart_calls[#jobstart_calls + 1] = {
    cmd = vim.deepcopy(cmd),
    opts = opts,
  }

  if type(opts) == "table" and type(opts.on_exit) == "function" then
    opts.on_exit(1, 0)
  end

  return 1
end

vim.schedule = function(fn)
  fn()
end

local ok, err = pcall(function()
  local bridge = require("ark.bridge")
  local config = {
    session_lib_path = runtime_root,
    session_pkg_path = vim.fn.getcwd() .. "/packages/arkbridge",
  }

  local ready, install_err = bridge.ensure_current_runtime(config, {
    on_build_complete = function(result)
      callbacks[#callbacks + 1] = result
    end,
    user_initiated = true,
  })

  if ready ~= nil or type(install_err) ~= "table" or install_err.kind ~= "build_pending" then
    error("expected stale runtime revision to block startup with build_pending, got " .. vim.inspect({
      ready = ready,
      err = install_err,
    }), 0)
  end
  if #deferred ~= 0 then
    error("expected runtime revision mismatch to avoid deferred freshness path, got " .. vim.inspect(deferred), 0)
  end
  if #jobstart_calls ~= 1 then
    error("expected runtime revision mismatch to start immediate install, got " .. tostring(#jobstart_calls), 0)
  end
  if #callbacks ~= 1 or callbacks[1].ok ~= true then
    error("expected immediate install to notify build completion listener, got " .. vim.inspect(callbacks), 0)
  end
end)

vim.defer_fn = original_defer_fn
vim.fn.executable = original_executable
vim.fn.jobstart = original_jobstart
vim.schedule = original_schedule
vim.fn.delete(runtime_root, "rf")

if not ok then
  error(err, 0)
end
