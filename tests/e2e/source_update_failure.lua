-- Failed background builds must retain the old installation, report failure,
-- and avoid a rebuild/notification loop on subsequent buffer entries.
local identity = require("ark.identity")
local binary = vim.fn.getcwd() .. "/target/release/ark-lsp"
local before = identity.binary_signature(binary)
identity.snapshot = function(_, component, callback)
  if component == "plugin" then callback({ fingerprint = "plugin" }); return end
  callback({ fingerprint = "wanted", built = { source_fingerprint = "old", profile = "release" } })
end
local jobs, messages = 0, {}
vim.notify = function(message) messages[#messages + 1] = tostring(message) end
vim.fn.jobstart = function(_, opts)
  jobs = jobs + 1
  vim.schedule(function() opts.on_exit(1, 1) end)
  return 1
end
local dev = require("ark.dev")
assert(dev.ensure_current_detached_lsp_cmd({ binary }, {}))
assert(vim.wait(1000, function() return identity.state(binary).phase == "failed" end))
for _ = 1, 100 do assert(dev.ensure_current_detached_lsp_cmd({ binary }, {})) end
assert(jobs == 1)
assert(identity.binary_signature(binary) == before)
assert(table.concat(messages, "\n"):find("failed", 1, true))
assert(not vim.tbl_contains(messages, "Ark LSP updated and active"))
