vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.bridge"] = nil

local runtime_root = vim.fn.tempname()
local installed_dir = runtime_root .. "/arkbridge"
local stamp_path = runtime_root .. "/.arkbridge-install.json"

vim.fn.mkdir(installed_dir, "p")
vim.fn.writefile({
  vim.json.encode({
    source_mtime = 4102444800,
  }),
}, stamp_path)

local deferred = {}
local rg_calls = 0

local original_defer_fn = vim.defer_fn
local original_executable = vim.fn.executable
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

  local ready_one, err_one = bridge.ensure_current_runtime(config, {})
  local ready_two, err_two = bridge.ensure_current_runtime(config, {})

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
end)

vim.defer_fn = original_defer_fn
vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist
vim.fn.delete(runtime_root, "rf")

if not ok then
  error(err, 0)
end
