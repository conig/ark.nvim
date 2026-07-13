vim.opt.rtp:prepend(vim.fn.getcwd())

local original_executable = vim.fn.executable
local original_has = vim.fn.has

local function has(entries, kind, needle)
  for _, entry in ipairs(entries) do
    if entry.kind == kind and entry.message:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local ok, err = xpcall(function()
  -- Reproduce the real Linux startup shape: Ark advertises recursive workspace
  -- watching, but Neovim cannot use its scalable inotifywait backend.
  vim.fn.has = function(feature)
    if feature == "linux" then
      return 1
    end
    return original_has(feature)
  end
  vim.fn.executable = function(path)
    if path == "inotifywait" then
      return 0
    end
    return original_executable(path)
  end

  local missing = require("ark.health").collect()
  assert(has(missing, "warn", "inotify-tools"), vim.inspect(missing))
  assert(has(missing, "warn", "large workspaces"), vim.inspect(missing))
  assert(has(missing, "warn", "lsp.file_watch = false"), vim.inspect(missing))

  vim.fn.executable = function(path)
    if path == "inotifywait" then
      return 1
    end
    return original_executable(path)
  end

  local installed = require("ark.health").collect()
  assert(has(installed, "ok", "inotifywait"), vim.inspect(installed))
  assert(not has(installed, "warn", "inotify-tools"), vim.inspect(installed))

  require("ark").setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    lsp = { file_watch = false },
  })
  vim.fn.executable = function(path)
    if path == "inotifywait" then
      return 0
    end
    return original_executable(path)
  end

  local disabled = require("ark.health").collect()
  assert(not has(disabled, "warn", "inotify-tools"), vim.inspect(disabled))
end, debug.traceback)

vim.fn.executable = original_executable
vim.fn.has = original_has

if not ok then
  error(err, 0)
end
