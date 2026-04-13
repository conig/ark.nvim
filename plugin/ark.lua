vim.api.nvim_create_user_command("ArkPaneStart", function()
  require("ark").start_pane()
end, { desc = "Start or reuse the visible managed ark.nvim R tab" })

vim.api.nvim_create_user_command("ArkPaneRestart", function()
  require("ark").restart_pane()
end, { desc = "Restart the active managed ark.nvim R tab" })

vim.api.nvim_create_user_command("ArkPaneStop", function()
  require("ark").stop_pane()
end, { desc = "Stop all managed ark.nvim R tabs" })

vim.api.nvim_create_user_command("ArkTabNew", function()
  require("ark").new_tab()
end, { desc = "Create a new managed ark.nvim R tab" })

vim.api.nvim_create_user_command("ArkTabNext", function()
  require("ark").next_tab()
end, { desc = "Switch to the next managed ark.nvim R tab" })

vim.api.nvim_create_user_command("ArkTabPrev", function()
  require("ark").prev_tab()
end, { desc = "Switch to the previous managed ark.nvim R tab" })

vim.api.nvim_create_user_command("ArkTabClose", function()
  require("ark").close_tab()
end, { desc = "Close the active managed ark.nvim R tab" })

vim.api.nvim_create_user_command("ArkTabList", function()
  vim.print(require("ark").list_tabs())
end, { desc = "Print the managed ark.nvim R tabs" })

vim.api.nvim_create_user_command("ArkTabGo", function(args)
  require("ark").go_tab(args.args)
end, {
  desc = "Switch to the managed ark.nvim R tab at the given index",
  nargs = 1,
})

vim.api.nvim_create_user_command("ArkLspStart", function()
  require("ark").start_lsp(0)
end, { desc = "Start ark.nvim LSP for the current buffer" })

vim.api.nvim_create_user_command("ArkHelp", function()
  require("ark").help(0)
end, { desc = "Show full help for the symbol under cursor in a read-only floating window" })

vim.api.nvim_create_user_command("ArkHelpPane", function()
  require("ark").help_pane(0)
end, { desc = "Send help for the symbol under cursor to the managed ark.nvim R pane" })

vim.api.nvim_create_user_command("ArkView", function(args)
  local expr = args.args ~= "" and args.args or nil
  require("ark").view(expr, 0)
end, {
  desc = "Open the Ark data explorer for an expression or the symbol under cursor",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkViewRefresh", function()
  require("ark").view_refresh()
end, { desc = "Refresh the current Ark data explorer tab" })

vim.api.nvim_create_user_command("ArkViewClose", function()
  require("ark").view_close()
end, { desc = "Close the current Ark data explorer tab" })

vim.api.nvim_create_user_command("ArkSnippets", function()
  require("ark").snippets(0)
end, { desc = "Open the Ark snippets picker for the current R-family buffer" })

vim.api.nvim_create_user_command("ArkRefresh", function()
  require("ark").refresh(0)
end, { desc = "Restart ark.nvim LSP for the current buffer with current pane state" })

vim.api.nvim_create_user_command("ArkStatus", function()
  vim.print(require("ark").status({ include_lsp = true }))
end, { desc = "Print ark.nvim status" })

vim.api.nvim_create_user_command("ArkPaneCommand", function()
  vim.print(require("ark").pane_command())
end, { desc = "Print the shell command used for the managed ark.nvim pane" })
