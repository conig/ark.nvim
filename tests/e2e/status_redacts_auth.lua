local ark = require("ark")

local session = require("ark.session")
local original_status = session.status
session.status = function()
  return {
    startup_status = {
      auth_token = "do-not-print",
      bridge_schema = "v1",
    },
  }
end

local ok, err = xpcall(function()
  ark.setup({ auto_start_pane = false, auto_start_lsp = false })
  local public = ark.status()
  assert(public.startup_status.auth_token == "<redacted>", vim.inspect(public))
  local private = ark.status({ include_secrets = true })
  assert(private.startup_status.auth_token == "do-not-print", vim.inspect(private))
end, debug.traceback)

session.status = original_status
if not ok then
  error(err, 0)
end
