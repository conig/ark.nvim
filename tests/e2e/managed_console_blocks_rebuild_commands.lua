vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark"] = nil
package.loaded["ark.blink"] = {
  ensure_integration = function() end,
}
package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function() end,
}
package.loaded["ark.snippets"] = {}
package.loaded["ark.view"] = {}

local original_standalone = vim.env.ARK_NVIM_CONSOLE_STANDALONE
local original_managed = vim.env.ARK_NVIM_MANAGED_PANE
local original_backend = vim.env.ARK_SESSION_BACKEND
local original_session = vim.env.ARK_SESSION_ID
local original_jobstart = vim.fn.jobstart
local jobstart_calls = {}

vim.fn.jobstart = function(cmd, opts)
  jobstart_calls[#jobstart_calls + 1] = cmd
  return original_jobstart(cmd, opts)
end

vim.env.ARK_NVIM_CONSOLE_STANDALONE = "1"
vim.env.ARK_NVIM_MANAGED_PANE = "1"
vim.env.ARK_SESSION_BACKEND = "tmux"
vim.env.ARK_SESSION_ID = "tmux_socket__tmux_session__tmux_pane"

local ok, err = pcall(function()
  local ark = require("ark")
  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    configure_slime = false,
  })

  -- Managed nvim-console panes are runtime consumers owned by the parent
  -- editor. They must not start local rebuilds that race the parent process.
  pcall(vim.cmd, "ArkBuildLsp")
  pcall(vim.cmd, "ArkBuildBridge")

  if #jobstart_calls ~= 0 then
    error("managed console should not start rebuild jobs: " .. vim.inspect(jobstart_calls), 0)
  end
end)

vim.env.ARK_NVIM_CONSOLE_STANDALONE = original_standalone
vim.env.ARK_NVIM_MANAGED_PANE = original_managed
vim.env.ARK_SESSION_BACKEND = original_backend
vim.env.ARK_SESSION_ID = original_session
vim.fn.jobstart = original_jobstart
package.loaded["ark"] = nil

if not ok then
  error(err, 0)
end
