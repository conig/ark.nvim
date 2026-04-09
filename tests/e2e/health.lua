vim.opt.rtp:prepend(vim.fn.getcwd())

local reports = {}
local original_health = vim.health
local original_executable = vim.fn.executable
local original_systemlist = vim.fn.systemlist
local original_tmux = vim.env.TMUX
local original_lsp_bin = vim.env.ARK_NVIM_LSP_BIN
local original_launcher = vim.env.ARK_NVIM_LAUNCHER
local original_status_dir = vim.env.ARK_STATUS_DIR

local temp_root = vim.fn.tempname()
local lsp_bin = temp_root .. "-ark-lsp"
local launcher = temp_root .. "-launcher.sh"
local status_dir = temp_root .. "-status"
vim.fn.mkdir(status_dir, "p")
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, lsp_bin)
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, launcher)
vim.fn.setfperm(lsp_bin, "rwxr-xr-x")
vim.fn.setfperm(launcher, "rwxr-xr-x")
vim.fn.writefile({ "{}" }, status_dir .. "/session.json")

vim.health = {
  start = function(message)
    reports[#reports + 1] = { kind = "start", message = message }
  end,
  ok = function(message)
    reports[#reports + 1] = { kind = "ok", message = message }
  end,
  warn = function(message)
    reports[#reports + 1] = { kind = "warn", message = message }
  end,
  error = function(message)
    reports[#reports + 1] = { kind = "error", message = message }
  end,
  info = function(message)
    reports[#reports + 1] = { kind = "info", message = message }
  end,
}

vim.fn.executable = function(path)
  if path == "tmux" or path == "R" or path == lsp_bin or path == launcher then
    return 1
  end
  return original_executable(path)
end

vim.fn.systemlist = function(cmd)
  if type(cmd) == "table" and cmd[1] == "R" and cmd[2] == "--version" then
    return { "R version 4.4.1" }
  end
  if type(cmd) == "table" and cmd[1] == "R" and cmd[2] == "--slave" then
    return { "yes" }
  end
  return original_systemlist(cmd)
end

vim.env.TMUX = ""
vim.env.ARK_NVIM_LSP_BIN = lsp_bin
vim.env.ARK_NVIM_LAUNCHER = launcher
vim.env.ARK_STATUS_DIR = status_dir

local ok, err = pcall(function()
  package.loaded["ark.health"] = nil
  require("ark.health").check()

  local saw_start = false
  local saw_tmux_warn = false
  local saw_jsonlite_ok = false
  local saw_status_ok = false
  local saw_error = false

  for _, report in ipairs(reports) do
    if report.kind == "start" and report.message == "ark.nvim" then
      saw_start = true
    end
    if report.kind == "warn" and report.message:find("not running inside tmux", 1, true) then
      saw_tmux_warn = true
    end
    if report.kind == "ok" and report.message:find("jsonlite", 1, true) then
      saw_jsonlite_ok = true
    end
    if report.kind == "ok" and report.message:find("Status directory is present", 1, true) then
      saw_status_ok = true
    end
    if report.kind == "error" then
      saw_error = true
    end
  end

  if not saw_start then
    error("expected health report start entry, got " .. vim.inspect(reports), 0)
  end
  if not saw_tmux_warn then
    error("expected tmux warning in health report, got " .. vim.inspect(reports), 0)
  end
  if not saw_jsonlite_ok then
    error("expected jsonlite success in health report, got " .. vim.inspect(reports), 0)
  end
  if not saw_status_ok then
    error("expected status directory success in health report, got " .. vim.inspect(reports), 0)
  end
  if saw_error then
    error("did not expect health errors, got " .. vim.inspect(reports), 0)
  end
end)

vim.health = original_health
vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist
vim.env.TMUX = original_tmux
vim.env.ARK_NVIM_LSP_BIN = original_lsp_bin
vim.env.ARK_NVIM_LAUNCHER = original_launcher
vim.env.ARK_STATUS_DIR = original_status_dir

if not ok then
  error(err, 0)
end
