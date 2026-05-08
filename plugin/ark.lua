vim.lsp.commands["ark.targetAction"] = function(command, ctx)
  local args = command.arguments or {}
  local payload = args[1] or {}
  local action = payload.action
  local name = payload.name or ""
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local ark = require("ark")

  if action == "make" or action == "load" or action == "invalidate" then
    vim.print(ark.targets_action(action, name, bufnr))
  elseif action == "makeDownstream" then
    vim.print(ark.targets_action("make_downstream", name, bufnr))
  elseif action == "status" then
    ark.targets_status(name, bufnr)
  elseif action == "log" then
    ark.targets_log(name, bufnr)
  elseif action == "objectMeta" then
    vim.print(ark.targets_object_meta(name, bufnr))
  elseif action == "graph" then
    ark.targets_graph(bufnr)
  else
    vim.notify("Unknown ark.nvim target action: " .. tostring(action), vim.log.levels.WARN, {
      title = "ark.nvim",
    })
  end
end

vim.api.nvim_create_user_command("ArkPaneStart", function()
  require("ark").start_pane()
end, { desc = "Start or reuse the managed ark.nvim R session" })

vim.api.nvim_create_user_command("ArkPaneRestart", function()
  require("ark").restart_pane()
end, { desc = "Restart the active managed ark.nvim R session" })

vim.api.nvim_create_user_command("ArkPaneStop", function()
  require("ark").stop_pane()
end, { desc = "Stop the managed ark.nvim R session(s)" })

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
end, { desc = "Send help for the symbol under cursor to the managed ark.nvim R session" })

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

vim.api.nvim_create_user_command("ArkTargetsInfo", function()
  vim.print(require("ark").targets_project_info(0))
end, { desc = "Print target project information for the current buffer" })

vim.api.nvim_create_user_command("ArkTargets", function()
  vim.print(require("ark").targets_manifest(0))
end, { desc = "Print the target manifest for the current buffer" })

vim.api.nvim_create_user_command("ArkTargetsManifest", function()
  vim.print(require("ark").targets_manifest(0))
end, { desc = "Print the target manifest for the current buffer" })

vim.api.nvim_create_user_command("ArkTargetPick", function()
  require("ark").targets_pick(0)
end, { desc = "Pick and remember the active target for the current project" })

vim.api.nvim_create_user_command("ArkTargetAcquire", function()
  require("ark").targets_pick(0)
end, { desc = "Pick and remember the active target for the current project" })

vim.api.nvim_create_user_command("ArkTargetActive", function()
  local name, err = require("ark").targets_active(0)
  if name then
    vim.notify("Active target: " .. name, vim.log.levels.INFO, { title = "ark.nvim" })
  else
    vim.notify(err or "No active target set.", vim.log.levels.WARN, { title = "ark.nvim" })
  end
end, { desc = "Show the active target for the current project" })

vim.api.nvim_create_user_command("ArkTargetGraph", function()
  require("ark").targets_graph(0)
end, { desc = "Open the target graph for the current buffer" })

vim.api.nvim_create_user_command("ArkTargetsNetwork", function()
  require("ark").targets_graph(0)
end, { desc = "Open the target graph for the current buffer" })

vim.api.nvim_create_user_command("ArkTargetStatus", function(args)
  require("ark").targets_status(args.args, 0)
end, {
  desc = "Open target status metadata; accepts optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetsMeta", function(args)
  vim.print(require("ark").targets_meta(args.args, 0))
end, {
  desc = "Print target cache metadata; accepts optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetObjectMeta", function(args)
  vim.print(require("ark").targets_object_meta(args.args, 0))
end, {
  desc = "Print bounded object metadata for one target",
  nargs = 1,
})

vim.api.nvim_create_user_command("ArkTargetBuild", function(args)
  vim.print(require("ark").targets_action("make", args.args, 0))
end, {
  desc = "Run targets::tar_make() for optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetBuildPick", function()
  require("ark").targets_action_pick("make", 0)
end, { desc = "Pick a target and run targets::tar_make() for it" })

vim.api.nvim_create_user_command("ArkTargetBuildActive", function()
  vim.print(require("ark").targets_action_active("make", 0))
end, { desc = "Run targets::tar_make() for the active target" })

vim.api.nvim_create_user_command("ArkTargetBuildDownstream", function(args)
  vim.print(require("ark").targets_action("make_downstream", args.args, 0))
end, {
  desc = "Run targets::tar_make() for a target and its downstream dependents",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetBuildDownstreamPick", function()
  require("ark").targets_action_pick("make_downstream", 0)
end, { desc = "Pick a target and run targets::tar_make() for it and downstream dependents" })

vim.api.nvim_create_user_command("ArkTargetMake", function(args)
  vim.print(require("ark").targets_action("make", args.args, 0))
end, {
  desc = "Run targets::tar_make() for optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetInvalidate", function(args)
  vim.print(require("ark").targets_action("invalidate", args.args, 0))
end, {
  desc = "Run targets::tar_invalidate() for optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetInvalidatePick", function()
  require("ark").targets_action_pick("invalidate", 0)
end, { desc = "Pick a target and run targets::tar_invalidate() for it" })

vim.api.nvim_create_user_command("ArkTargetLoad", function(args)
  vim.print(require("ark").targets_action("load", args.args, 0))
end, {
  desc = "Run targets::tar_load() for optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetLoadPick", function()
  require("ark").targets_action_pick("load", 0)
end, { desc = "Pick a target and run targets::tar_load() for it" })

vim.api.nvim_create_user_command("ArkTargetLoadActive", function()
  vim.print(require("ark").targets_action_active("load", 0))
end, { desc = "Run targets::tar_load() for the active target" })

vim.api.nvim_create_user_command("ArkTargetLog", function(args)
  require("ark").targets_log(args.args, 0)
end, {
  desc = "Open target log/status metadata; accepts optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkSnippets", function()
  require("ark").snippets(0)
end, { desc = "Open the Ark snippets picker for the current R-family buffer" })

vim.api.nvim_create_user_command("ArkSend", function(args)
  require("ark").send(args.args)
end, {
  desc = "Send text to the active managed ark.nvim R session",
  nargs = "+",
})

vim.api.nvim_create_user_command("ArkRefresh", function()
  require("ark").refresh(0)
end, { desc = "Restart ark.nvim LSP for the current buffer with current pane state" })

vim.api.nvim_create_user_command("ArkStatus", function()
  vim.print(require("ark").status({ include_lsp = true }))
end, { desc = "Print ark.nvim status" })

vim.api.nvim_create_user_command("ArkPaneCommand", function()
  vim.print(require("ark").pane_command())
end, { desc = "Print the shell command used for the managed ark.nvim session" })
