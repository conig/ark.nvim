-- Normal release startup must return immediately, then check once asynchronously.
local identity = require("ark.identity")
local binary = vim.fn.getcwd() .. "/target/release/ark-lsp"
local checks, builds = 0, 0
identity.snapshot = function(_, component, callback)
  if component == "plugin" then callback({ fingerprint = "plugin" }); return end
  checks = checks + 1
  callback({ fingerprint = "current", built = { profile = "release", source_fingerprint = "current" } })
end
vim.fn.jobstart = function() builds = builds + 1; error("current binary must not build") end
local dev = require("ark.dev")
local cmd = { binary, "--runtime-mode", "detached" }
for _ = 1, 10 do
  local result, err = dev.ensure_current_detached_lsp_cmd(cmd, { development_mode = false })
  assert(err == nil and vim.deep_equal(result, cmd))
end
assert(checks == 0 and builds == 0, "freshness work blocked startup")
assert(vim.wait(1000, function() return checks > 0 end))
assert(checks == 1 and builds == 0, "freshness checks were not coalesced")
