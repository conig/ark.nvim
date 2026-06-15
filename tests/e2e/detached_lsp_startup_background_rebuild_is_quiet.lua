vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local uv = vim.uv or vim.loop
local root = vim.fn.getcwd()
local target_dir = root .. "/target/debug"
local built_binary = target_dir .. "/ark-lsp"
local source_probe = vim.fn.tempname()

vim.fn.mkdir(target_dir, "p")
local built_binary_existed = vim.fn.filereadable(built_binary) == 1
if not built_binary_existed then
  vim.fn.writefile({ "# fake ark-lsp binary for startup no-auto-build test" }, built_binary)
end
vim.fn.writefile({ "// newer source probe" }, source_probe)

local now = os.time()
pcall(uv.fs_utime, built_binary, now - 200, now - 200)
pcall(uv.fs_utime, source_probe, now, now)

local original_executable = vim.fn.executable
local original_systemlist = vim.fn.systemlist
local original_jobstart = vim.fn.jobstart

local job_opts = nil
local completed = nil

vim.fn.executable = function(cmd)
  if cmd == "cargo" or cmd == "rg" then
    return 1
  end
  return original_executable(cmd)
end

vim.fn.systemlist = function(cmd)
  if type(cmd) == "table" and cmd[1] == "rg" then
    return { source_probe }
  end
  return original_systemlist(cmd)
end

vim.fn.jobstart = function(cmd, opts)
  if not vim.deep_equal(cmd, { "cargo", "build", "-p", "ark-lsp" }) then
    error("unexpected build command: " .. vim.inspect(cmd), 0)
  end
  job_opts = opts
  return 4242
end

local function build_float()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:find("ark.nvim is rebuilding detached ark-lsp.", 1, true) then
        return win, buf, text
      end
    end
  end
  return nil, nil, nil
end

local ok, err = pcall(function()
  local dev = require("ark.dev")
  local cmd = { built_binary, "--runtime-mode", "detached" }

  local resolved, resolve_err = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), {
    on_build_complete = function(result)
      completed = result
    end,
  })
  if resolve_err ~= nil then
    error("unexpected detached ark-lsp resolution error: " .. vim.inspect(resolve_err), 0)
  end
  if not vim.deep_equal(resolved, cmd) then
    error("expected existing detached binary to be returned immediately", 0)
  end

  local started = vim.wait(1000, function()
    return job_opts ~= nil
  end, 20, false)
  if not started then
    error("expected stale startup freshness probe to start one parent-side background rebuild", 0)
  end

  if build_float() ~= nil then
    error("implicit startup rebuild should not open the detached ark-lsp build float", 0)
  end

  job_opts.on_stdout(4242, { "    Finished dev [unoptimized] target(s)", "" })
  job_opts.on_exit(4242, 0)
  local finished = vim.wait(1000, function()
    return type(completed) == "table"
  end, 20, false)
  if not finished or completed.ok ~= true then
    error("expected successful background rebuild completion, got " .. vim.inspect(completed), 0)
  end
end)

vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist
vim.fn.jobstart = original_jobstart
vim.fn.delete(source_probe)
if not built_binary_existed then
  vim.fn.delete(built_binary)
end

if not ok then
  error(err, 0)
end
