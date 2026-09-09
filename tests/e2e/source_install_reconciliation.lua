-- Exercise real Neovim LSP transport in NORMAL mode in a disposable checkout.
-- Cargo publication is controlled, but the replacement is the actual native
-- release binary and activation must be confirmed by its initialize response.
local repo = vim.fn.getcwd()
local candidate = repo .. "/target/release/ark-lsp"
local result = vim.system({ candidate, "--source-identity", repo }, { text = true }):wait()
assert(result.code == 0, result.stderr)
local snapshot = vim.json.decode(result.stdout)
assert(snapshot.fingerprint == snapshot.built.source_fingerprint, "rebuild release binary before this test")
local root = vim.env.ARK_TEST_TMPDIR .. "/checkout"
vim.fn.mkdir(root, "p")
for _, entry in ipairs(snapshot.inputs) do
  local destination = root .. entry.path:sub(#repo + 1)
  if vim.uv.fs_stat(entry.path).type == "directory" then vim.fn.mkdir(destination, "p") else
    vim.fn.mkdir(vim.fs.dirname(destination), "p")
    assert(vim.uv.fs_copyfile(entry.path, destination))
  end
end
for _, directory in ipairs({ "lua", "plugin" }) do
  assert(vim.system({ "cp", "-a", repo .. "/" .. directory, root .. "/" }):wait().code == 0)
end
vim.fn.mkdir(root .. "/target/release", "p")
vim.fn.mkdir(root .. "/bin", "p")
local binary = root .. "/target/release/ark-lsp"
assert(vim.uv.fs_copyfile(repo .. "/tests/fixtures/stale-lsp.py", binary))
vim.fn.setfperm(binary, "rwxr-xr-x")
local log = root .. "/cargo.log"
vim.fn.writefile({ "#!/bin/sh", "printf '%s\\n' \"$*\" >> " .. vim.fn.shellescape(log),
  "sleep 0.4", "cp " .. vim.fn.shellescape(candidate) .. " " .. vim.fn.shellescape(binary .. ".new"),
  "mv " .. vim.fn.shellescape(binary .. ".new") .. " " .. vim.fn.shellescape(binary),
}, root .. "/bin/cargo")
vim.fn.setfperm(root .. "/bin/cargo", "rwxr-xr-x")
vim.env.PATH = root .. "/bin:" .. vim.env.PATH
vim.env.ARK_NVIM_DEV_MODE = "0"
vim.env.ARK_NVIM_LSP_BIN = nil
vim.opt.rtp:prepend(root)
local messages = {}
vim.notify = function(message) messages[#messages + 1] = tostring(message) end
local ark = require("ark")
ark.setup({ auto_start_pane = false, auto_start_lsp = false, configure_slime = false })
vim.cmd("edit " .. root .. "/probe.R")
vim.bo.filetype = "r"
local config = ark.lsp_config()
assert(config.cmd[1] == binary, "normal mode selected another installation")
ark.start_lsp()
local identity = require("ark.identity")
assert(vim.wait(20000, function() return identity.state(binary).phase == "current" end, 10), vim.inspect(identity.state(binary)))
local clients
assert(vim.wait(5000, function()
  clients = vim.lsp.get_clients({ name = "ark_lsp" })
  return #clients == 1 and clients[1].initialized and not clients[1]:is_stopped()
end, 10), "old LSP was not replaced")
assert(clients[1].server_capabilities.experimental.arkBuild.build_id == snapshot.built.build_id)
assert(identity.state(binary).running.build_id == snapshot.built.build_id)
assert(vim.deep_equal(vim.fn.readfile(log), { "build -p ark-lsp --release" }), "wrong profile or duplicate build")
assert(vim.tbl_contains(messages, "Updating Ark LSP…"), vim.inspect(messages))
assert(vim.tbl_contains(messages, "Ark LSP updated and active"), vim.inspect(messages))
-- Cached/no-change calls must not rebuild, spawn hashing workers, or notify.
local system, spawned = vim.system, 0
vim.system = function(...) spawned = spawned + 1; return system(...) end
local count = #messages
local start = vim.uv.hrtime()
for _ = 1, 100 do require("ark.dev").ensure_current_detached_lsp_cmd(config.cmd, {}) end
local elapsed = (vim.uv.hrtime() - start) / 1e6
assert(elapsed < 100, "cached checks materially blocked the editor: " .. elapsed .. "ms")
vim.wait(300, function() return false end)
assert(spawned == 0 and #messages == count)
vim.print({ cached_100_checks_ms = elapsed, activated_build = snapshot.built.build_id })
for _, client in ipairs(clients) do client:stop(true) end
