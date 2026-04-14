vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local original_executable = vim.fn.executable
local original_systemlist = vim.fn.systemlist

local rg_calls = 0
local source_probe = vim.fn.tempname()
vim.fn.writefile({ "probe" }, source_probe)

vim.fn.executable = function(path)
  if path == "rg" then
    return 1
  end
  if path == "cargo" then
    return 0
  end
  return original_executable(path)
end

vim.fn.systemlist = function(command)
  if type(command) == "table" and command[1] == "rg" then
    rg_calls = rg_calls + 1
    return { source_probe }
  end

  return original_systemlist(command)
end

local ok, err = pcall(function()
  local dev = require("ark.dev")
  local probe_cmd = {
    vim.fn.getcwd() .. "/target/debug/ark-lsp-cache-probe",
    "--runtime-mode",
    "detached",
  }

  local _, first_err = dev.ensure_current_detached_lsp_cmd(probe_cmd, {})
  local _, second_err = dev.ensure_current_detached_lsp_cmd(probe_cmd, {})
  if type(first_err) ~= "string" or type(second_err) ~= "string" then
    error("expected stale detached binary checks to fail without cargo, got " .. vim.inspect({
      first_err = first_err,
      second_err = second_err,
    }), 0)
  end

  if rg_calls ~= 1 then
    error("expected detached source scan to be cached across immediate retries, saw " .. tostring(rg_calls), 0)
  end
end)

vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist

if not ok then
  error(err, 0)
end
