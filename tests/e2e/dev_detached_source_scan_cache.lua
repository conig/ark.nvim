-- The native worker hashes once. Repeated/concurrent unchanged checks only stat
-- its inventory, including directories needed to detect additions/deletions.
local identity = require("ark.identity")
local binary = vim.fn.getcwd() .. "/target/debug/ark-lsp"
local system = vim.system
local probes = 0
vim.system = function(cmd, ...)
  if cmd[2] == "--source-identity" then probes = probes + 1 end
  return system(cmd, ...)
end
local completed = 0
local function checked(snapshot, err)
  assert(snapshot and not err, tostring(err))
  assert(#snapshot.inputs > 0)
  completed = completed + 1
end
for _ = 1, 10 do identity.snapshot(binary, "lsp", checked) end
assert(vim.wait(10000, function() return completed == 10 end))
identity.snapshot(binary, "lsp", checked)
assert(vim.wait(10000, function() return completed == 11 end))
assert(probes == 1, "unchanged inputs spawned another hashing worker")
