vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local binary_path = vim.fn.getcwd() .. "/target/debug/ark-lsp-missing-rg-probe"
vim.fn.mkdir(vim.fs.dirname(binary_path), "p")
vim.fn.writefile({ "probe" }, binary_path)

local original_executable = vim.fn.executable
local original_glob = vim.fn.glob
local original_jobstart = vim.fn.jobstart
local original_notify = vim.notify
local glob_calls = 0
local cargo_calls = 0
local notifications = {}

vim.fn.executable = function(path)
  if path == "rg" then
    return 0
  end
  return original_executable(path)
end

vim.fn.glob = function(...)
  glob_calls = glob_calls + 1
  return original_glob(...)
end

vim.fn.jobstart = function(cmd, opts)
  if type(cmd) == "table" and cmd[1] == "cargo" then
    cargo_calls = cargo_calls + 1
  end
  return original_jobstart(cmd, opts)
end

vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = tostring(message),
    level = level,
    opts = opts,
  }
end

local ok, err = pcall(function()
  local dev = require("ark.dev")
  local cmd = { binary_path, "--runtime-mode", "detached" }
  local resolve_opts = { development_mode = true }

  local resolved_one, err_one = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), resolve_opts)
  local resolved_two, err_two = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), resolve_opts)
  if err_one ~= nil or err_two ~= nil or not vim.deep_equal(resolved_one, cmd) or not vim.deep_equal(resolved_two, cmd) then
    error("missing rg should not prevent use of an existing development binary: " .. vim.inspect({
      resolved_one = resolved_one,
      resolved_two = resolved_two,
      err_one = err_one,
      err_two = err_two,
    }), 0)
  end

  local warned = vim.wait(1000, function()
    return #notifications > 0
  end, 10, false)
  if not warned then
    error("expected an actionable missing-rg warning", 0)
  end
  if #notifications ~= 1
    or not notifications[1].message:find("`rg`", 1, true)
    or not notifications[1].message:find(":ArkBuildLsp", 1, true)
  then
    error("unexpected missing-rg warning: " .. vim.inspect(notifications), 0)
  end
  if glob_calls ~= 0 or cargo_calls ~= 0 then
    error("missing rg must skip recursive discovery and automatic rebuilds: " .. vim.inspect({
      glob_calls = glob_calls,
      cargo_calls = cargo_calls,
    }), 0)
  end
end)

vim.fn.executable = original_executable
vim.fn.glob = original_glob
vim.fn.jobstart = original_jobstart
vim.notify = original_notify
vim.fn.delete(binary_path)
package.loaded["ark.dev"] = nil

if not ok then
  error(err, 0)
end
