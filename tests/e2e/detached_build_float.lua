vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local uv = vim.uv or vim.loop
local root = vim.fn.getcwd()
local target_dir = root .. "/target/debug"
local built_binary = target_dir .. "/ark-lsp"
local probe_binary = target_dir .. "/ark-lsp-float-probe"
local source_probe = vim.fn.tempname()

vim.fn.mkdir(target_dir, "p")
local built_binary_existed = vim.fn.filereadable(built_binary) == 1
if not built_binary_existed then
  vim.fn.writefile({ "# fake ark-lsp binary for build-float test" }, built_binary)
end
vim.fn.writefile({ "# stale binary probe" }, probe_binary)
vim.fn.writefile({ "// newer source probe" }, source_probe)

local now = os.time()
pcall(uv.fs_utime, probe_binary, now - 200, now - 200)
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

local function build_log_buffer_text()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if text:find("ark.nvim is rebuilding detached ark-lsp.", 1, true) then
        return text
      end
    end
  end
  return ""
end

local ok, err = pcall(function()
  local dev = require("ark.dev")
  local cmd = { probe_binary, "--runtime-mode", "detached" }

  local resolved, resolve_err = dev.ensure_current_detached_lsp_cmd(vim.deepcopy(cmd), {
    on_build_complete = function(result)
      completed = result
    end,
  })
  if resolve_err ~= nil then
    error("unexpected stale binary resolution error: " .. vim.inspect(resolve_err), 0)
  end
  if not vim.deep_equal(resolved, cmd) then
    error("expected stale-but-usable detached binary to be returned immediately", 0)
  end

  local started = vim.wait(1000, function()
    return job_opts ~= nil
  end, 20, false)
  if not started then
    error("timed out waiting for background detached ark-lsp rebuild to start", 0)
  end

  local win, buf, text = build_float()
  if not win or not buf then
    error("expected automatic detached ark-lsp rebuild to open a floating log window", 0)
  end
  if not text:find("Press q to close this window", 1, true) then
    error("expected build float to document q close behavior: " .. vim.inspect(text), 0)
  end
  if not text:find("$ cargo build -p ark-lsp", 1, true) then
    error("expected build float to show cargo command: " .. vim.inspect(text), 0)
  end

  job_opts.on_stderr(4242, { "   Compiling ark-lsp v0.1.0", "" })
  local streamed = vim.wait(1000, function()
    local _, _, current_text = build_float()
    return type(current_text) == "string" and current_text:find("Compiling ark-lsp", 1, true) ~= nil
  end, 20, false)
  if not streamed then
    error("expected cargo output to stream into the build float", 0)
  end

  vim.api.nvim_set_current_win(win)
  vim.cmd("normal q")
  local closed = vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(win)
  end, 20, false)
  if not closed then
    error("expected q to close the build float", 0)
  end

  job_opts.on_stdout(4242, { "    Finished dev [unoptimized] target(s)", "" })
  vim.wait(100, function()
    return false
  end, 20, false)
  if build_float() ~= nil then
    error("closed build float should not reopen on later cargo output", 0)
  end

  job_opts.on_exit(4242, 0)
  local finished = vim.wait(1000, function()
    return type(completed) == "table"
  end, 20, false)
  if not finished or completed.ok ~= true then
    error("expected build completion listener after closing float, got " .. vim.inspect(completed), 0)
  end
  if build_float() ~= nil then
    error("successful build should not reopen a user-closed build float", 0)
  end

  local final_text = build_log_buffer_text()
  if not final_text:find("detached ark-lsp rebuilt", 1, true) then
    error("expected hidden build log buffer to record ready status: " .. vim.inspect(final_text), 0)
  end
  if not final_text:find("Ark will attach or restart the LSP", 1, true) then
    error("expected ready status to describe follow-up LSP attach/restart: " .. vim.inspect(final_text), 0)
  end
end)

vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist
vim.fn.jobstart = original_jobstart
vim.fn.delete(probe_binary)
vim.fn.delete(source_probe)
if not built_binary_existed then
  vim.fn.delete(built_binary)
end

if not ok then
  error(err, 0)
end
