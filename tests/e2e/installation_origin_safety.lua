-- A setup() command override must reach the managed terminal's actual launcher,
-- not leave it pointing at a different binary from config.defaults().
local ark = require("ark")
local external = vim.fn.tempname()
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, external)
vim.fn.setfperm(external, "rwxr-xr-x")
ark.setup({ auto_start_pane = false, auto_start_lsp = false, configure_slime = false,
  lsp = { cmd = { external, "--runtime-mode", "detached" } }, session = { backend = "terminal" },
})
local command = assert(ark.pane_command())
assert(command:find("ARK_NVIM_LSP_BIN=" .. vim.fn.shellescape(external), 1, true), command)
local dev = require("ark.dev")
local started, err = dev.build_detached_lsp({ binary_path = external })
assert(not started and tostring(err):find("not owned", 1, true), "external binary was rebuilt")
assert(vim.fn.readfile(external)[2] == "exit 0")
vim.env.ARK_NVIM_MANAGED_PANE = "1"
local snapshot = require("ark.identity").snapshot
require("ark.identity").snapshot = function() error("managed child must not probe/build") end
local binary = vim.fn.getcwd() .. "/target/release/ark-lsp"
assert(dev.ensure_current_detached_lsp_cmd({ binary }, {}))
vim.wait(20, function() return false end)
require("ark.identity").snapshot = snapshot
vim.fn.delete(external)
