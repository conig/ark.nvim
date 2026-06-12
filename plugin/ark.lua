vim.lsp.commands["ark.targetAction"] = function(command, ctx)
  local args = command.arguments or {}
  local payload = args[1] or {}
  local action = payload.action
  local name = payload.name or ""
  local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local ark = require("ark")

  if action == "make" or action == "load" or action == "invalidate" then
    if type(ark.targets_action_user) == "function" then
      ark.targets_action_user(action, name, bufnr)
    else
      vim.print(ark.targets_action(action, name, bufnr))
    end
  elseif action == "makeDownstream" then
    if type(ark.targets_action_user) == "function" then
      ark.targets_action_user("make_downstream", name, bufnr)
    else
      vim.print(ark.targets_action("make_downstream", name, bufnr))
    end
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

local function join_args(args, start)
  return table.concat(vim.list_slice(args, start), " ")
end

local function print_result(value)
  vim.print(value)
end

local function run_target_action(ark, action, names, bufnr)
  if type(ark.targets_action_user) == "function" then
    return ark.targets_action_user(action, names, bufnr)
  end
  return print_result(ark.targets_action(action, names, bufnr))
end

local function run_command(name)
  if vim.fn.exists(":" .. name) ~= 2 then
    vim.notify(":" .. name .. " is not available; has require('ark').setup() run?", vim.log.levels.ERROR, {
      title = "ark.nvim",
    })
    return
  end

  vim.cmd(name)
end

local function unknown_ark_command(args)
  local rendered = table.concat(args or {}, " ")
  if rendered == "" then
    rendered = "<empty>"
  end
  vim.notify("Unknown ark.nvim command: " .. rendered, vim.log.levels.WARN, {
    title = "ark.nvim",
  })
end

local ark_command_completions = {
  "build-bridge",
  "build-lsp",
  "help",
  "help pane",
  "lsp start",
  "pane command",
  "pane restart",
  "pane start",
  "pane stop",
  "packages install-missing",
  "refresh",
  "send",
  "snippets",
  "status",
  "tab close",
  "tab go",
  "tab list",
  "tab new",
  "tab next",
  "tab prev",
  "targets active",
  "targets build",
  "targets build-active",
  "targets build-downstream",
  "targets build-downstream-pick",
  "targets build-pick",
  "targets graph",
  "targets info",
  "targets invalidate",
  "targets invalidate-pick",
  "targets load",
  "targets load-active",
  "targets load-pick",
  "targets log",
  "targets make",
  "targets manifest",
  "targets meta",
  "targets network",
  "targets object-meta",
  "targets pick",
  "targets status",
  "view",
  "view close",
  "view refresh",
}

local function complete_ark_command(_, cmdline)
  local prefix = vim.trim((cmdline or ""):gsub("^%s*Ark!?", ""))
  local matches = {}
  for _, candidate in ipairs(ark_command_completions) do
    if vim.startswith(candidate, prefix) then
      matches[#matches + 1] = candidate
    end
  end
  return matches
end

local function dispatch_targets_command(args)
  local subcommand = args[2]
  local names = join_args(args, 3)
  local ark = require("ark")

  if subcommand == "info" then
    print_result(ark.targets_project_info(0))
  elseif subcommand == "manifest" then
    print_result(ark.targets_manifest(0))
  elseif subcommand == "pick" then
    ark.targets_pick(0)
  elseif subcommand == "active" then
    local name, err = ark.targets_active(0)
    if name then
      vim.notify("Active target: " .. name, vim.log.levels.INFO, { title = "ark.nvim" })
    else
      vim.notify(err or "No active target set.", vim.log.levels.WARN, { title = "ark.nvim" })
    end
  elseif subcommand == "graph" or subcommand == "network" then
    ark.targets_graph(0)
  elseif subcommand == "status" then
    ark.targets_status(names, 0)
  elseif subcommand == "meta" then
    print_result(ark.targets_meta(names, 0))
  elseif subcommand == "object-meta" then
    print_result(ark.targets_object_meta(names, 0))
  elseif subcommand == "build" or subcommand == "make" then
    run_target_action(ark, "make", names, 0)
  elseif subcommand == "build-pick" then
    ark.targets_action_pick("make", 0)
  elseif subcommand == "build-active" then
    print_result(ark.targets_action_active("make", 0))
  elseif subcommand == "build-downstream" then
    run_target_action(ark, "make_downstream", names, 0)
  elseif subcommand == "build-downstream-pick" then
    ark.targets_action_pick("make_downstream", 0)
  elseif subcommand == "invalidate" then
    run_target_action(ark, "invalidate", names, 0)
  elseif subcommand == "invalidate-pick" then
    ark.targets_action_pick("invalidate", 0)
  elseif subcommand == "load" then
    run_target_action(ark, "load", names, 0)
  elseif subcommand == "load-pick" then
    ark.targets_action_pick("load", 0)
  elseif subcommand == "load-active" then
    print_result(ark.targets_action_active("load", 0))
  elseif subcommand == "log" then
    ark.targets_log(names, 0)
  else
    unknown_ark_command(args)
  end
end

local function dispatch_ark_command(args)
  local top = args[1]
  local ark = require("ark")

  if top == nil or top == "" or top == "status" then
    print_result(ark.status({ include_lsp = true }))
  elseif top == "refresh" then
    ark.refresh(0)
  elseif top == "snippets" then
    ark.snippets(0)
  elseif top == "send" then
    ark.send(join_args(args, 2))
  elseif top == "build-lsp" then
    run_command("ArkBuildLsp")
  elseif top == "build-bridge" then
    run_command("ArkBuildBridge")
  elseif top == "pane" then
    local subcommand = args[2]
    if subcommand == "start" then
      ark.start_pane()
    elseif subcommand == "restart" then
      ark.restart_pane()
    elseif subcommand == "stop" then
      ark.stop_pane()
    elseif subcommand == "command" then
      print_result(ark.pane_command())
    else
      unknown_ark_command(args)
    end
  elseif top == "tab" then
    local subcommand = args[2]
    if subcommand == "new" then
      ark.new_tab()
    elseif subcommand == "next" then
      ark.next_tab()
    elseif subcommand == "prev" then
      ark.prev_tab()
    elseif subcommand == "close" then
      ark.close_tab()
    elseif subcommand == "list" then
      print_result(ark.list_tabs())
    elseif subcommand == "go" then
      ark.go_tab(args[3] or "")
    else
      unknown_ark_command(args)
    end
  elseif top == "lsp" and args[2] == "start" then
    ark.start_lsp(0)
  elseif top == "packages" and args[2] == "install-missing" then
    ark.install_missing_packages(0)
  elseif top == "help" then
    if args[2] == "pane" then
      ark.help_pane(0)
    else
      ark.help(0)
    end
  elseif top == "view" then
    if args[2] == "refresh" then
      ark.view_refresh()
    elseif args[2] == "close" then
      ark.view_close()
    else
      local expr = join_args(args, 2)
      ark.view(expr ~= "" and expr or nil, 0)
    end
  elseif top == "targets" then
    dispatch_targets_command(args)
  else
    unknown_ark_command(args)
  end
end

vim.api.nvim_create_user_command("Ark", function(args)
  dispatch_ark_command(args.fargs)
end, {
  complete = complete_ark_command,
  desc = "Run an ark.nvim command",
  nargs = "*",
})

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

vim.api.nvim_create_user_command("ArkInstallMissingPackages", function()
  require("ark").install_missing_packages(0)
end, { desc = "Install R packages reported missing by ark.nvim diagnostics" })

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
  local ark = require("ark")
  run_target_action(ark, "make", args.args, 0)
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
  local ark = require("ark")
  run_target_action(ark, "make_downstream", args.args, 0)
end, {
  desc = "Run targets::tar_make() for a target and its downstream dependents",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetBuildDownstreamPick", function()
  require("ark").targets_action_pick("make_downstream", 0)
end, { desc = "Pick a target and run targets::tar_make() for it and downstream dependents" })

vim.api.nvim_create_user_command("ArkTargetMake", function(args)
  local ark = require("ark")
  run_target_action(ark, "make", args.args, 0)
end, {
  desc = "Run targets::tar_make() for optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetInvalidate", function(args)
  local ark = require("ark")
  run_target_action(ark, "invalidate", args.args, 0)
end, {
  desc = "Run targets::tar_invalidate() for optional target names",
  nargs = "?",
})

vim.api.nvim_create_user_command("ArkTargetInvalidatePick", function()
  require("ark").targets_action_pick("invalidate", 0)
end, { desc = "Pick a target and run targets::tar_invalidate() for it" })

vim.api.nvim_create_user_command("ArkTargetLoad", function(args)
  local ark = require("ark")
  run_target_action(ark, "load", args.args, 0)
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
