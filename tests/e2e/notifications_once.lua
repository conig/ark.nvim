local original_notify = vim.notify
local calls = {}
vim.notify = function(message, level, opts)
  calls[#calls + 1] = { message = message, level = level, opts = opts }
  return #calls
end

local ok, err = xpcall(function()
  local notifications = require("ark.notifications")
  notifications.clear()
  notifications.emit("persistent failure", vim.log.levels.WARN, { ark_key = "failure" })
  notifications.emit("persistent failure", vim.log.levels.WARN, { ark_key = "failure" })
  notifications.emit("progress", vim.log.levels.INFO)
  notifications.emit("progress", vim.log.levels.INFO)
  assert(#calls == 3, vim.inspect(calls))
  notifications.clear("failure")
  notifications.emit("persistent failure", vim.log.levels.WARN, { ark_key = "failure" })
  assert(#calls == 4, vim.inspect(calls))
end, debug.traceback)

vim.notify = original_notify
if not ok then
  error(err, 0)
end
