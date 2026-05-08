vim.opt.rtp:prepend(vim.fn.getcwd())

local calls = {}

package.loaded["ark"] = {
  targets_project_info = function(bufnr)
    calls[#calls + 1] = { name = "info", bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_manifest = function(bufnr)
    calls[#calls + 1] = { name = "manifest", bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_pick = function(bufnr)
    calls[#calls + 1] = { name = "pick", bufnr = bufnr }
    return true
  end,
  targets_active = function(bufnr)
    calls[#calls + 1] = { name = "active", bufnr = bufnr }
    return "clean_data"
  end,
  targets_network = function(bufnr)
    calls[#calls + 1] = { name = "network", bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_graph = function(bufnr)
    calls[#calls + 1] = { name = "graph", bufnr = bufnr }
    return { bufnr = 7 }
  end,
  targets_meta = function(names, bufnr)
    calls[#calls + 1] = { name = "meta", names = names, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_status = function(names, bufnr)
    calls[#calls + 1] = { name = "status", names = names, bufnr = bufnr }
    return { bufnr = 8 }
  end,
  targets_log = function(names, bufnr)
    calls[#calls + 1] = { name = "log", names = names, bufnr = bufnr }
    return { bufnr = 9 }
  end,
  targets_object_meta = function(name, bufnr)
    calls[#calls + 1] = { name = "object_meta", target = name, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_action = function(action, names, bufnr)
    calls[#calls + 1] = { name = "action", action = action, names = names, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_action_pick = function(action, bufnr)
    calls[#calls + 1] = { name = "action_pick", action = action, bufnr = bufnr }
    return true
  end,
  targets_action_active = function(action, bufnr)
    calls[#calls + 1] = { name = "action_active", action = action, bufnr = bufnr }
    return { status = "ok" }
  end,
}

vim.cmd("runtime plugin/ark.lua")

vim.cmd("ArkTargetsInfo")
vim.cmd("ArkTargets")
vim.cmd("ArkTargetsManifest")
vim.cmd("ArkTargetPick")
vim.cmd("ArkTargetAcquire")
vim.cmd("ArkTargetActive")
vim.cmd("ArkTargetGraph")
vim.cmd("ArkTargetsNetwork")
vim.cmd("ArkTargetStatus clean_data")
vim.cmd("ArkTargetsMeta clean_data")
vim.cmd("ArkTargetObjectMeta clean_data")
vim.cmd("ArkTargetBuild clean_data")
vim.cmd("ArkTargetBuildPick")
vim.cmd("ArkTargetBuildActive")
vim.cmd("ArkTargetBuildDownstream clean_data")
vim.cmd("ArkTargetBuildDownstreamPick")
vim.cmd("ArkTargetMake clean_data")
vim.cmd("ArkTargetInvalidate clean_data")
vim.cmd("ArkTargetInvalidatePick")
vim.cmd("ArkTargetLoad clean_data")
vim.cmd("ArkTargetLoadPick")
vim.cmd("ArkTargetLoadActive")
vim.cmd("ArkTargetLog clean_data")

local command = vim.lsp.commands["ark.targetAction"]
if type(command) ~= "function" then
  error("ark.targetAction LSP command was not registered", 0)
end

command({ arguments = { { action = "make", name = "clean_data" } } }, { bufnr = 42 })
command({ arguments = { { action = "makeDownstream", name = "clean_data" } } }, { bufnr = 42 })
command({ arguments = { { action = "status", name = "clean_data" } } }, { bufnr = 42 })
command({ arguments = { { action = "log", name = "clean_data" } } }, { bufnr = 42 })
command({ arguments = { { action = "objectMeta", name = "clean_data" } } }, { bufnr = 42 })
command({ arguments = { { action = "graph", name = vim.NIL } } }, { bufnr = 42 })

local expected = {
  { name = "info", bufnr = 0 },
  { name = "manifest", bufnr = 0 },
  { name = "manifest", bufnr = 0 },
  { name = "pick", bufnr = 0 },
  { name = "pick", bufnr = 0 },
  { name = "active", bufnr = 0 },
  { name = "graph", bufnr = 0 },
  { name = "graph", bufnr = 0 },
  { name = "status", names = "clean_data", bufnr = 0 },
  { name = "meta", names = "clean_data", bufnr = 0 },
  { name = "object_meta", target = "clean_data", bufnr = 0 },
  { name = "action", action = "make", names = "clean_data", bufnr = 0 },
  { name = "action_pick", action = "make", bufnr = 0 },
  { name = "action_active", action = "make", bufnr = 0 },
  { name = "action", action = "make_downstream", names = "clean_data", bufnr = 0 },
  { name = "action_pick", action = "make_downstream", bufnr = 0 },
  { name = "action", action = "make", names = "clean_data", bufnr = 0 },
  { name = "action", action = "invalidate", names = "clean_data", bufnr = 0 },
  { name = "action_pick", action = "invalidate", bufnr = 0 },
  { name = "action", action = "load", names = "clean_data", bufnr = 0 },
  { name = "action_pick", action = "load", bufnr = 0 },
  { name = "action_active", action = "load", bufnr = 0 },
  { name = "log", names = "clean_data", bufnr = 0 },
  { name = "action", action = "make", names = "clean_data", bufnr = 42 },
  { name = "action", action = "make_downstream", names = "clean_data", bufnr = 42 },
  { name = "status", names = "clean_data", bufnr = 42 },
  { name = "log", names = "clean_data", bufnr = 42 },
  { name = "object_meta", target = "clean_data", bufnr = 42 },
  { name = "graph", bufnr = 42 },
}

if not vim.deep_equal(calls, expected) then
  error("unexpected target command calls: " .. vim.inspect(calls), 0)
end
