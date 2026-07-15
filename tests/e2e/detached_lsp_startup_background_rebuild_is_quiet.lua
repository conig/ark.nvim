vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local uv = vim.uv or vim.loop
local root = vim.fn.getcwd()
local target_dir = root .. "/target/debug"
local built_binary = target_dir .. "/ark-lsp"
local release_probe = root .. "/target/release/ark-lsp-profile-probe"
local source_probe = vim.fn.tempname()

vim.fn.mkdir(target_dir, "p")
vim.fn.mkdir(vim.fs.dirname(release_probe), "p")
local built_binary_existed = vim.fn.filereadable(built_binary) == 1
if not built_binary_existed then
  vim.fn.writefile({ "# fake ark-lsp binary for startup no-auto-build test" }, built_binary)
end
vim.fn.writefile({ "# stale release ark-lsp profile probe" }, release_probe)
vim.fn.writefile({ "// newer source probe" }, source_probe)

local now = os.time()
pcall(uv.fs_utime, built_binary, now - 200, now - 200)
pcall(uv.fs_utime, release_probe, now - 200, now - 200)
pcall(uv.fs_utime, source_probe, now, now)

local original_executable = vim.fn.executable
local original_jobstart = vim.fn.jobstart
local original_system = vim.system

local job_cmd = nil
local job_opts = nil
local completed = nil
local rg_calls = 0
local job_calls = 0

vim.fn.executable = function(cmd)
  if cmd == "cargo" or cmd == "rg" then
    return 1
  end
  return original_executable(cmd)
end

vim.system = function(cmd, opts, on_exit)
  if type(cmd) == "table" and cmd[1] == "rg" then
    rg_calls = rg_calls + 1
    vim.schedule(function()
      on_exit({ code = 0, stdout = source_probe .. "\n", stderr = "" })
    end)
    return {}
  end
  return original_system(cmd, opts, on_exit)
end

vim.fn.jobstart = function(cmd, opts)
  job_calls = job_calls + 1
  job_cmd = vim.deepcopy(cmd)
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
    development_mode = true,
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
  local repeated, repeated_err = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), {
    development_mode = true,
  })
  if repeated_err ~= nil or not vim.deep_equal(repeated, cmd) then
    error("unexpected repeated detached ark-lsp resolution: " .. vim.inspect({ repeated, repeated_err }), 0)
  end

  local started = vim.wait(1000, function()
    return job_opts ~= nil
  end, 20, false)
  if not started then
    error("expected stale startup freshness probe to start one parent-side background rebuild", 0)
  end
  if not vim.deep_equal(job_cmd, { "cargo", "build", "-p", "ark-lsp" }) then
    error("expected debug binary freshness to use a debug build, got " .. vim.inspect(job_cmd), 0)
  end
  if rg_calls ~= 1 or job_calls ~= 1 then
    error("concurrent freshness requests were not coalesced: " .. vim.inspect({
      rg_calls = rg_calls,
      job_calls = job_calls,
    }), 0)
  end

  if build_float() ~= nil then
    error("implicit startup rebuild should not open the detached ark-lsp build float", 0)
  end

  -- Regression: Cargo repeats its package-cache lock warning while another
  -- build owns the lock. Streaming those hidden background lines wakes the TUI
  -- for every chunk and makes the visible cursor flutter even though no build
  -- output is being shown. A quiet implicit rebuild must buffer both streams.
  if job_opts.stdout_buffered ~= true or job_opts.stderr_buffered ~= true then
    error(
      "expected hidden background rebuild output to be buffered, got "
        .. vim.inspect({
          stdout_buffered = job_opts.stdout_buffered,
          stderr_buffered = job_opts.stderr_buffered,
        }),
      0
    )
  end

  job_opts.on_stdout(4242, { "    Finished dev [unoptimized] target(s)", "" })
  job_opts.on_exit(4242, 0)
  local finished = vim.wait(1000, function()
    return type(completed) == "table"
  end, 20, false)
  if not finished or completed.ok ~= true then
    error("expected successful background rebuild completion, got " .. vim.inspect(completed), 0)
  end

  -- Regression: a freshness rebuild must update the binary Ark is actually
  -- running. Rebuilding debug while the configured release binary remains
  -- stale causes the completion callback to launch the same rebuild forever.
  job_cmd = nil
  job_opts = nil
  local release_resolved, release_err = dev.ensure_current_detached_lsp_cmd({
    release_probe,
    "--runtime-mode",
    "detached",
  }, { development_mode = true })
  if release_err ~= nil or release_resolved[1] ~= release_probe then
    error("unexpected release binary resolution: " .. vim.inspect({ release_resolved, release_err }), 0)
  end

  local release_started = vim.wait(1000, function()
    return job_opts ~= nil
  end, 20, false)
  if not release_started then
    error("expected stale release binary to start a background freshness rebuild", 0)
  end
  if rg_calls ~= 2 then
    error("expected one asynchronous source discovery per completed build generation, got " .. tostring(rg_calls), 0)
  end
  if job_calls ~= 2 then
    error("expected one build per stale binary generation, got " .. tostring(job_calls), 0)
  end
  if not vim.deep_equal(job_cmd, { "cargo", "build", "-p", "ark-lsp", "--release" }) then
    error("expected release binary freshness to use a release build, got " .. vim.inspect(job_cmd), 0)
  end
  if job_opts.stdout_buffered ~= true or job_opts.stderr_buffered ~= true then
    error("expected hidden release rebuild output to remain buffered", 0)
  end
end)

vim.fn.executable = original_executable
vim.fn.jobstart = original_jobstart
vim.system = original_system
vim.fn.delete(source_probe)
vim.fn.delete(release_probe)
if not built_binary_existed then
  vim.fn.delete(built_binary)
end

if not ok then
  error(err, 0)
end
