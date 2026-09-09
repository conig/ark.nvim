-- A stale release build must update in normal mode, without a focus-stealing
-- float or Cargo's streaming lock-wait chatter. Success means activation.
local identity = require("ark.identity")
local binary = vim.fn.getcwd() .. "/target/release/ark-lsp"
local snapshots = 0
identity.snapshot = function(_, component, callback)
  if component == "plugin" then callback({ fingerprint = "plugin" }); return end
  snapshots = snapshots + 1
  callback({ fingerprint = "new", built = { profile = "release", source_fingerprint = snapshots == 1 and "old" or "new" } })
end
local notifications, jobs, job = {}, 0
vim.notify = function(message) notifications[#notifications + 1] = message end
local executable = vim.fn.executable
vim.fn.executable = function(cmd) return cmd == "cargo" and 1 or executable(cmd) end
vim.fn.jobstart = function(cmd, opts)
  assert(vim.deep_equal(cmd, { "cargo", "build", "-p", "ark-lsp", "--release" }))
  assert(opts.stdout_buffered and opts.stderr_buffered)
  jobs, job = jobs + 1, opts
  return 4242
end
local completed = 0
local dev = require("ark.dev")
for _ = 1, 5 do
  local result, err = dev.ensure_current_detached_lsp_cmd({ binary }, {
    development_mode = false,
    on_build_complete = function(value) assert(value.ok); completed = completed + 1 end,
  })
  assert(result and not err)
end
assert(vim.wait(1000, function() return job ~= nil end), "stale release must update in normal mode")
assert(jobs == 1)
assert(notifications[1]:find("Updating Ark", 1, true))
for _, win in ipairs(vim.api.nvim_list_wins()) do assert(vim.api.nvim_win_get_config(win).relative == "") end
job.on_exit(4242, 0)
assert(vim.wait(1000, function() return completed == 5 end))
assert(identity.state(binary).phase == "restarting")
identity.activated(binary, { id = 1, server_capabilities = { experimental = { arkBuild = { source_fingerprint = "old" } } } })
assert(identity.state(binary).phase == "mismatch", "old process must not appear current")
identity.activated(binary, { id = 2, server_capabilities = { experimental = { arkBuild = { source_fingerprint = "new" } } } })
assert(identity.state(binary).phase == "current")
assert(notifications[#notifications] == "Ark LSP updated and active")
