vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local root = vim.fn.getcwd()
local binary_path = root .. "/target/debug/ark-lsp-probe"
vim.fn.mkdir(vim.fs.dirname(binary_path), "p")
vim.fn.writefile({ "# probe" }, binary_path)

local deferred = {}
local rg_calls = 0
local cargo_calls = 0

local original_defer_fn = vim.defer_fn
local original_executable = vim.fn.executable
local original_systemlist = vim.fn.systemlist
local original_jobstart = vim.fn.jobstart

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

vim.fn.jobstart = function(cmd, opts)
  if type(cmd) == "table" and cmd[1] == "cargo" then
    cargo_calls = cargo_calls + 1
  end
  return original_jobstart(cmd, opts)
end

local ok, err = pcall(function()
  local dev = require("ark.dev")
  local cmd = { binary_path, "--runtime-mode", "detached" }

  local resolve_opts = { development_mode = false }
  local resolved_one, err_one = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), resolve_opts)
  local resolved_two, err_two = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), resolve_opts)

  if err_one ~= nil or err_two ~= nil then
    error("unexpected detached build check error: " .. vim.inspect({ err_one, err_two }), 0)
  end
  if not vim.deep_equal(resolved_one, cmd) or not vim.deep_equal(resolved_two, cmd) then
    error("expected existing detached binary to be returned immediately", 0)
  end
  if rg_calls ~= 0 then
    error("expected no source scan on the startup path, got " .. tostring(rg_calls), 0)
  end
  if #deferred ~= 0 or rg_calls ~= 0 or cargo_calls ~= 0 then
    error("normal mode must not schedule, scan, or rebuild source binaries: " .. vim.inspect({
      deferred = #deferred,
      rg_calls = rg_calls,
      cargo_calls = cargo_calls,
    }), 0)
  end
end)

vim.defer_fn = original_defer_fn
vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist
vim.fn.jobstart = original_jobstart
vim.fn.delete(binary_path)

if not ok then
  error(err, 0)
end
