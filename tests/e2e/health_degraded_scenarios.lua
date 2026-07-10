local original_executable = vim.fn.executable
local original_systemlist = vim.fn.systemlist
local original_filewritable = vim.fn.filewritable
local original_backend = vim.env.ARK_NVIM_SESSION_BACKEND
local original_r_bin = vim.env.ARK_NVIM_R_BIN
local original_status_dir = vim.env.ARK_STATUS_DIR

local function has(entries, kind, needle)
  for _, entry in ipairs(entries) do
    if entry.kind == kind and entry.message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local ok, err = xpcall(function()
  vim.env.ARK_NVIM_SESSION_BACKEND = "tmux"
  vim.env.ARK_NVIM_R_BIN = "missing-R"
  vim.fn.executable = function(path)
    if path == "tmux" or path == "missing-R" then
      return 0
    end
    return original_executable(path)
  end
  local missing = require("ark.health").collect()
  assert(has(missing, "error", "install tmux or set session.backend"), vim.inspect(missing))
  assert(has(missing, "error", "install R 4.2+"), vim.inspect(missing))

  vim.env.ARK_NVIM_SESSION_BACKEND = "terminal"
  vim.env.ARK_NVIM_R_BIN = "R"
  vim.fn.executable = function(path)
    if path == "R" then
      return 1
    end
    return original_executable(path)
  end
  vim.fn.systemlist = function(cmd)
    if cmd[1] == "R" and cmd[2] == "--version" then
      return { "R version 4.4.1" }
    end
    if cmd[1] == "R" and cmd[2] == "--slave" then
      return { "no" }
    end
    return original_systemlist(cmd)
  end
  local terminal = require("ark.health").collect()
  assert(has(terminal, "ok", "Neovim terminal support"), vim.inspect(terminal))
  assert(has(terminal, "error", "install.packages('jsonlite')"), vim.inspect(terminal))
  assert(not has(terminal, "error", "tmux"), vim.inspect(terminal))

  local status_dir = vim.fn.tempname()
  vim.fn.mkdir(status_dir, "p")
  vim.fn.writefile({ vim.json.encode({
    status = "ready",
    product_version = "stale",
    bridge_schema = "v0",
  }) }, status_dir .. "/stale.json")
  vim.env.ARK_STATUS_DIR = status_dir
  local stale = require("ark.health").collect()
  assert(has(stale, "error", "ready bridge status file(s) are incompatible"), vim.inspect(stale))

  vim.fn.filewritable = function()
    return 0
  end
  local readonly = require("ark.health").collect()
  assert(has(readonly, "error", "install location is not writable"), vim.inspect(readonly))
  assert(has(readonly, "error", "state location is not writable"), vim.inspect(readonly))

  vim.fn.filewritable = original_filewritable
  vim.env.ARK_STATUS_DIR = original_status_dir
  require("ark").setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    session = { backend = "terminal" },
  })
  vim.env.ARK_NVIM_SESSION_BACKEND = "tmux"
  local configured = require("ark.health").collect()
  assert(has(configured, "ok", "Configured session backend: terminal"), vim.inspect(configured))
  assert(not has(configured, "error", "tmux"), vim.inspect(configured))
end, debug.traceback)

vim.fn.executable = original_executable
vim.fn.systemlist = original_systemlist
vim.fn.filewritable = original_filewritable
vim.env.ARK_NVIM_SESSION_BACKEND = original_backend
vim.env.ARK_NVIM_R_BIN = original_r_bin
vim.env.ARK_STATUS_DIR = original_status_dir

if not ok then
  error(err, 0)
end
