vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.bridge"] = nil

local runtime_root = vim.fn.tempname()
local installed_dir = runtime_root .. "/arkbridge"
local stamp_path = runtime_root .. "/.arkbridge-install.json"
local generated_object = runtime_root .. "/ipc.o"

vim.fn.mkdir(installed_dir, "p")
vim.fn.writefile({ "generated" }, generated_object)
assert((vim.uv or vim.loop).fs_utime(generated_object, 2100000000, 2100000000))
vim.fn.writefile({
  vim.json.encode({
    source_mtime = 2000000000,
    runtime_revision = 2,
  }),
}, stamp_path)

local deferred = {}
local jobstart_calls = 0

local original_defer_fn = vim.defer_fn
local original_executable = vim.fn.executable
local original_jobstart = vim.fn.jobstart
local original_systemlist = vim.fn.systemlist

vim.defer_fn = function(fn, timeout_ms)
  deferred[#deferred + 1] = {
    fn = fn,
    timeout_ms = timeout_ms,
  }
  return #deferred
end

vim.fn.executable = function(cmd)
  if cmd == "rg" or cmd == "R" then
    return 1
  end
  return original_executable(cmd)
end

vim.fn.systemlist = function(cmd)
  if type(cmd) == "table" and cmd[1] == "rg" then
    -- R package installation compiles these files in the source tree. They
    -- are outputs, not a source change that should trigger another install.
    return { generated_object }
  end
  return original_systemlist(cmd)
end

vim.fn.jobstart = function()
  jobstart_calls = jobstart_calls + 1
  return 1
end

local ok, err = pcall(function()
  local bridge = require("ark.bridge")
  local config = {
    session_lib_path = runtime_root,
    session_pkg_path = vim.fn.getcwd() .. "/packages/arkbridge",
  }

  local ready, ready_err = bridge.ensure_current_runtime(config, {})
  if ready ~= true or ready_err ~= nil then
    error("expected installed bridge runtime to be immediately usable", 0)
  end
  if #deferred ~= 1 then
    error("expected one deferred freshness probe, got " .. tostring(#deferred), 0)
  end

  deferred[1].fn()

  if jobstart_calls ~= 0 then
    error("expected generated R package build artifacts not to trigger a reinstall", 0)
  end
end)

vim.defer_fn = original_defer_fn
vim.fn.executable = original_executable
vim.fn.jobstart = original_jobstart
vim.fn.systemlist = original_systemlist
vim.fn.delete(runtime_root, "rf")

if not ok then
  error(err, 0)
end
