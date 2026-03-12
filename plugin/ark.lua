vim.api.nvim_create_user_command("ArkPaneStart", function()
  require("ark").start_pane()
end, { desc = "Start or reuse the managed ark.nvim R pane" })

vim.api.nvim_create_user_command("ArkPaneRestart", function()
  require("ark").restart_pane()
end, { desc = "Restart the managed ark.nvim R pane" })

vim.api.nvim_create_user_command("ArkPaneStop", function()
  require("ark").stop_pane()
end, { desc = "Stop the managed ark.nvim R pane" })

vim.api.nvim_create_user_command("ArkLspStart", function()
  require("ark").start_lsp(0)
end, { desc = "Start ark.nvim LSP for the current buffer" })

vim.api.nvim_create_user_command("ArkRefresh", function()
  require("ark").refresh(0)
end, { desc = "Restart ark.nvim LSP for the current buffer with current pane state" })

vim.api.nvim_create_user_command("ArkStatus", function()
  vim.print(require("ark").status())
end, { desc = "Print ark.nvim status" })

vim.api.nvim_create_user_command("ArkPaneCommand", function()
  vim.print(require("ark").pane_command())
end, { desc = "Print the shell command used for the managed ark.nvim pane" })
