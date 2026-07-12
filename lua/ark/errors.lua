local M = {}

local catalog = {
  E_CONFIG = { state = "unsupported", action = "Fix the named require('ark').setup() key or value, then restart Neovim." },
  E_INSTALL = { state = "update_in_progress", action = "Run :Ark install again; pin the previous plugin release before using :Ark rollback." },
  E_LSP_UNAVAILABLE = { state = "static_only", action = "Run :Ark install, then :Ark refresh." },
  E_BACKEND_UNAVAILABLE = { state = "static_only", action = "Install the configured backend requirement or select session.backend = 'terminal'." },
  E_BRIDGE_MISSING = { state = "live_degraded", action = "Run :Ark pane restart; use :checkhealth ark if it remains unavailable." },
  E_BRIDGE_INCOMPATIBLE = { state = "restart_required", action = "Run :Ark install and :Ark pane restart so plugin, LSP, and bridge versions match." },
  E_IPC_AUTH = { state = "live_degraded", action = "Run :Ark refresh; restart the pane if the stale session identity persists." },
  E_IPC_REQUEST = { state = "live_degraded", action = "Retry the action; run :Ark report if the request remains invalid." },
  E_IPC_DECODE = { state = "live_degraded", action = "Retry after :Ark refresh; collect :Ark report if decoding still fails." },
  E_IPC_HANDLER = { state = "live_degraded", action = "Run :Ark pane restart, then retry the operation." },
  E_IPC_BOOTSTRAP = { state = "live_degraded", action = "Run :Ark pane restart, then :Ark refresh." },
  E_IPC_HELP = { state = "live_degraded", action = "Confirm the help topic exists, then retry after :Ark refresh." },
  E_IPC_PACKAGE_INFO = { state = "live_degraded", action = "Confirm the package is installed in the managed R library." },
  E_IPC_PACKAGE_INSTALL = { state = "live_degraded", action = "Review the managed R package-install output and retry explicitly." },
  E_IPC_VIEW = { state = "live_degraded", action = "Reopen ArkView; restart the pane if the view still fails." },
  E_IPC_VIEW_GONE = { state = "live_degraded", action = "Reopen ArkView for the object." },
  E_IPC_VIEW_TYPE = { state = "live_degraded", action = "Open a rectangular table or a supported list object in ArkView." },
  E_IPC_TARGETS = { state = "live_degraded", action = "Check the targets project with :Ark targets info and :checkhealth ark." },
  E_TARGET_VIEW = { state = "live_degraded", action = "Close and reopen the target ArkView worker." },
  E_EVAL = { state = "live_degraded", action = "Confirm the object exists in the managed R session and retry." },
}

function M.lookup(code)
  return catalog[code] or {
    state = "live_degraded",
    action = "Run :Ark status and :Ark report, then inspect :checkhealth ark.",
  }
end

function M.format(code, message)
  local entry = M.lookup(code)
  return string.format("[%s] %s Recovery: %s", code, tostring(message or "Ark operation failed."), entry.action)
end

function M.catalog()
  return vim.deepcopy(catalog)
end

return M
