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
  targets_network = function(bufnr)
    calls[#calls + 1] = { name = "network", bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_meta = function(names, bufnr)
    calls[#calls + 1] = { name = "meta", names = names, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_object_meta = function(name, bufnr)
    calls[#calls + 1] = { name = "object_meta", target = name, bufnr = bufnr }
    return { status = "ok" }
  end,
  targets_action = function(action, names, bufnr)
    calls[#calls + 1] = { name = "action", action = action, names = names, bufnr = bufnr }
    return { status = "ok" }
  end,
}

vim.cmd("runtime plugin/ark.lua")

vim.cmd("ArkTargetsInfo")
vim.cmd("ArkTargets")
vim.cmd("ArkTargetsManifest")
vim.cmd("ArkTargetGraph")
vim.cmd("ArkTargetsNetwork")
vim.cmd("ArkTargetStatus clean_data")
vim.cmd("ArkTargetsMeta clean_data")
vim.cmd("ArkTargetObjectMeta clean_data")
vim.cmd("ArkTargetBuild clean_data")
vim.cmd("ArkTargetMake clean_data")
vim.cmd("ArkTargetInvalidate clean_data")
vim.cmd("ArkTargetLoad clean_data")

local expected = {
  { name = "info", bufnr = 0 },
  { name = "manifest", bufnr = 0 },
  { name = "manifest", bufnr = 0 },
  { name = "network", bufnr = 0 },
  { name = "network", bufnr = 0 },
  { name = "meta", names = "clean_data", bufnr = 0 },
  { name = "meta", names = "clean_data", bufnr = 0 },
  { name = "object_meta", target = "clean_data", bufnr = 0 },
  { name = "action", action = "make", names = "clean_data", bufnr = 0 },
  { name = "action", action = "make", names = "clean_data", bufnr = 0 },
  { name = "action", action = "invalidate", names = "clean_data", bufnr = 0 },
  { name = "action", action = "load", names = "clean_data", bufnr = 0 },
}

if not vim.deep_equal(calls, expected) then
  error("unexpected target command calls: " .. vim.inspect(calls), 0)
end
