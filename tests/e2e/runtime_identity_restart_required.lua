local helper = dofile(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua")
local lib = helper.run_tmpdir() .. "/r-lib"
helper.setup_managed_buffer(helper.run_tmpdir() .. "/identity.R", { "1 + 1" }, {
  tmux = { session_lib_path = lib },
})
local ark, bridge = require("ark"), require("ark.bridge")
local status = ark.status()
local loaded = status.startup_status.runtime_identity
assert(type(loaded) == "table" and type(loaded.source_fingerprint) == "string" and loaded.source_fingerprint ~= "",
  "new R session did not report its loaded install identity")
local pid = status.startup_status.pid
local config = require("ark.session").runtime_config(ark.options())
local function live() return ark.status().startup_status end
bridge.reconcile(config, ark.options().lsp.cmd[1], live)
assert(vim.wait(10000, function() return bridge.status().update.phase == "current" end))
-- Model publishing a replacement installation while R still holds the old
-- namespace. Never modify the user's R library or restart their session.
local path = lib .. "/.arkbridge-install.json"
local stamp = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
stamp.source_fingerprint = "replacement"
vim.fn.writefile({ vim.json.encode(stamp) }, path)
local identity, snapshot = require("ark.identity"), require("ark.identity").snapshot
identity.snapshot = function(binary, component, callback, force)
  if component == "bridge" then callback({ fingerprint = "replacement" }) else snapshot(binary, component, callback, force) end
end
local messages = {}
vim.notify = function(message) messages[#messages + 1] = tostring(message) end
vim.wait(1100, function() return false end)
bridge.reconcile(config, ark.options().lsp.cmd[1], live)
assert(vim.wait(5000, function() return bridge.status().update.phase == "restart_required" end))
assert(ark.status().startup_status.pid == pid and ark.status().bridge_ready, "update restarted R")
assert(ark.status().startup_status.runtime_identity.source_fingerprint == loaded.source_fingerprint)
assert(table.concat(messages, "\n"):find("R session restart required", 1, true))
