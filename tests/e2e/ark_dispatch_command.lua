vim.opt.rtp:prepend(vim.fn.getcwd())

local calls = {}

package.loaded["ark"] = {
  close_tab = function()
    calls[#calls + 1] = { name = "close_tab" }
  end,
  go_tab = function(index)
    calls[#calls + 1] = { name = "go_tab", index = index }
  end,
  help = function(bufnr)
    calls[#calls + 1] = { name = "help", bufnr = bufnr }
  end,
  help_pane = function(bufnr)
    calls[#calls + 1] = { name = "help_pane", bufnr = bufnr }
  end,
  install_missing_packages = function(bufnr)
    calls[#calls + 1] = { name = "install_missing_packages", bufnr = bufnr }
  end,
  list_tabs = function()
    calls[#calls + 1] = { name = "list_tabs" }
    return { status = "ok" }
  end,
  new_tab = function()
    calls[#calls + 1] = { name = "new_tab" }
  end,
  next_tab = function()
    calls[#calls + 1] = { name = "next_tab" }
  end,
  pane_command = function()
    calls[#calls + 1] = { name = "pane_command" }
    return "R --vanilla"
  end,
  prev_tab = function()
    calls[#calls + 1] = { name = "prev_tab" }
  end,
  refresh = function(bufnr)
    calls[#calls + 1] = { name = "refresh", bufnr = bufnr }
  end,
  restart_pane = function()
    calls[#calls + 1] = { name = "restart_pane" }
  end,
  send = function(text)
    calls[#calls + 1] = { name = "send", text = text }
  end,
  snippets = function(bufnr)
    calls[#calls + 1] = { name = "snippets", bufnr = bufnr }
  end,
  start_lsp = function(bufnr)
    calls[#calls + 1] = { name = "start_lsp", bufnr = bufnr }
  end,
  start_pane = function()
    calls[#calls + 1] = { name = "start_pane" }
  end,
  status = function(opts)
    calls[#calls + 1] = { name = "status", include_lsp = opts and opts.include_lsp }
    return { status = "ok" }
  end,
  stop_pane = function()
    calls[#calls + 1] = { name = "stop_pane" }
  end,
  targets_action = function(action, names, bufnr)
    calls[#calls + 1] = { name = "target_action", action = action, names = names, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_action_active = function(action, bufnr)
    calls[#calls + 1] = { name = "target_action_active", action = action, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_action_pick = function(action, bufnr)
    calls[#calls + 1] = { name = "target_action_pick", action = action, bufnr = bufnr }
  end,
  targets_active = function(bufnr)
    calls[#calls + 1] = { name = "target_active", bufnr = bufnr }
    return "clean_data"
  end,
  targets_graph = function(bufnr)
    calls[#calls + 1] = { name = "target_graph", bufnr = bufnr }
  end,
  targets_log = function(names, bufnr)
    calls[#calls + 1] = { name = "target_log", names = names, bufnr = bufnr }
  end,
  targets_manifest = function(bufnr)
    calls[#calls + 1] = { name = "target_manifest", bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_meta = function(names, bufnr)
    calls[#calls + 1] = { name = "target_meta", names = names, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_object_meta = function(name, bufnr)
    calls[#calls + 1] = { name = "target_object_meta", target = name, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_pick = function(bufnr)
    calls[#calls + 1] = { name = "target_pick", bufnr = bufnr }
  end,
  targets_project_info = function(bufnr)
    calls[#calls + 1] = { name = "target_info", bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_status = function(names, bufnr)
    calls[#calls + 1] = { name = "target_status", names = names, bufnr = bufnr }
  end,
  view = function(expr, bufnr)
    calls[#calls + 1] = { name = "view", expr = expr, bufnr = bufnr }
  end,
  view_close = function()
    calls[#calls + 1] = { name = "view_close" }
  end,
  view_refresh = function()
    calls[#calls + 1] = { name = "view_refresh" }
  end,
}

vim.cmd("runtime plugin/ark.lua")

vim.api.nvim_create_user_command("ArkBuildLsp", function()
  calls[#calls + 1] = { name = "build_lsp" }
end, {})

vim.api.nvim_create_user_command("ArkBuildBridge", function()
  calls[#calls + 1] = { name = "build_bridge" }
end, {})

vim.cmd("Ark")
vim.cmd("Ark status")
vim.cmd("Ark refresh")
vim.cmd("Ark snippets")
vim.cmd("Ark send print(1)")
vim.cmd("Ark build-lsp")
vim.cmd("Ark build-bridge")
vim.cmd("Ark pane start")
vim.cmd("Ark pane restart")
vim.cmd("Ark pane stop")
vim.cmd("Ark pane command")
vim.cmd("Ark tab new")
vim.cmd("Ark tab next")
vim.cmd("Ark tab prev")
vim.cmd("Ark tab close")
vim.cmd("Ark tab list")
vim.cmd("Ark tab go 2")
vim.cmd("Ark lsp start")
vim.cmd("Ark packages install-missing")
vim.cmd("Ark help")
vim.cmd("Ark help pane")
vim.cmd("Ark view")
vim.cmd("Ark view mtcars")
vim.cmd("Ark view refresh")
vim.cmd("Ark view close")
vim.cmd("Ark targets info")
vim.cmd("Ark targets manifest")
vim.cmd("Ark targets pick")
vim.cmd("Ark targets active")
vim.cmd("Ark targets graph")
vim.cmd("Ark targets network")
vim.cmd("Ark targets status clean_data")
vim.cmd("Ark targets meta clean_data")
vim.cmd("Ark targets object-meta clean_data")
vim.cmd("Ark targets build clean_data")
vim.cmd("Ark targets build-pick")
vim.cmd("Ark targets build-active")
vim.cmd("Ark targets build-downstream clean_data")
vim.cmd("Ark targets build-downstream-pick")
vim.cmd("Ark targets make clean_data")
vim.cmd("Ark targets invalidate clean_data")
vim.cmd("Ark targets invalidate-pick")
vim.cmd("Ark targets load clean_data")
vim.cmd("Ark targets load-pick")
vim.cmd("Ark targets load-active")
vim.cmd("Ark targets log clean_data")

local expected = {
  { name = "status", include_lsp = true },
  { name = "status", include_lsp = true },
  { name = "refresh", bufnr = 0 },
  { name = "snippets", bufnr = 0 },
  { name = "send", text = "print(1)" },
  { name = "build_lsp" },
  { name = "build_bridge" },
  { name = "start_pane" },
  { name = "restart_pane" },
  { name = "stop_pane" },
  { name = "pane_command" },
  { name = "new_tab" },
  { name = "next_tab" },
  { name = "prev_tab" },
  { name = "close_tab" },
  { name = "list_tabs" },
  { name = "go_tab", index = "2" },
  { name = "start_lsp", bufnr = 0 },
  { name = "install_missing_packages", bufnr = 0 },
  { name = "help", bufnr = 0 },
  { name = "help_pane", bufnr = 0 },
  { name = "view", expr = nil, bufnr = 0 },
  { name = "view", expr = "mtcars", bufnr = 0 },
  { name = "view_refresh" },
  { name = "view_close" },
  { name = "target_info", bufnr = 0 },
  { name = "target_manifest", bufnr = 0 },
  { name = "target_pick", bufnr = 0 },
  { name = "target_active", bufnr = 0 },
  { name = "target_graph", bufnr = 0 },
  { name = "target_graph", bufnr = 0 },
  { name = "target_status", names = "clean_data", bufnr = 0 },
  { name = "target_meta", names = "clean_data", bufnr = 0 },
  { name = "target_object_meta", target = "clean_data", bufnr = 0 },
  { name = "target_action", action = "make", names = "clean_data", bufnr = 0 },
  { name = "target_action_pick", action = "make", bufnr = 0 },
  { name = "target_action_active", action = "make", bufnr = 0 },
  { name = "target_action", action = "make_downstream", names = "clean_data", bufnr = 0 },
  { name = "target_action_pick", action = "make_downstream", bufnr = 0 },
  { name = "target_action", action = "make", names = "clean_data", bufnr = 0 },
  { name = "target_action", action = "invalidate", names = "clean_data", bufnr = 0 },
  { name = "target_action_pick", action = "invalidate", bufnr = 0 },
  { name = "target_action", action = "load", names = "clean_data", bufnr = 0 },
  { name = "target_action_pick", action = "load", bufnr = 0 },
  { name = "target_action_active", action = "load", bufnr = 0 },
  { name = "target_log", names = "clean_data", bufnr = 0 },
}

if not vim.deep_equal(calls, expected) then
  error("unexpected Ark dispatcher calls: " .. vim.inspect(calls), 0)
end

local completions = vim.fn.getcompletion("Ark targets b", "cmdline")
if not vim.tbl_contains(completions, "targets build") then
  error("expected Ark dispatcher completion to include targets build, got " .. vim.inspect(completions), 0)
end

local package_completions = vim.fn.getcompletion("Ark packages i", "cmdline")
if not vim.tbl_contains(package_completions, "packages install-missing") then
  error("expected Ark dispatcher completion to include packages install-missing, got " .. vim.inspect(package_completions), 0)
end
