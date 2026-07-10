local M = {}
local seen = {}

function M.emit(message, level, opts)
  level = level or vim.log.levels.INFO
  opts = vim.tbl_extend("force", { title = "ark.nvim" }, opts or {})
  local key = opts.ark_key or tostring(message)
  opts.ark_key = nil

  if level >= vim.log.levels.WARN then
    if seen[key] then
      return nil
    end
    seen[key] = true
  end
  return vim.notify(message, level, opts)
end

function M.clear(key)
  if key == nil then
    seen = {}
  else
    seen[key] = nil
  end
end

return M
