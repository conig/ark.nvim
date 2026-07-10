local M = {}

local definitions = {
  live_ready = { works = "static and live language features", action = nil },
  static_starting = { works = "static language features", action = nil },
  static_only = { works = "static language features", action = "Check :Ark status when live features are needed." },
  live_degraded = { works = "static language features", action = "Run :Ark pane restart, then :Ark refresh." },
  update_in_progress = { works = "existing static features", action = "Wait for installation to finish." },
  restart_required = { works = "static language features", action = "Run :Ark pane restart, then :Ark refresh." },
  unsupported = { works = "no supported guarantee", action = "Fix :checkhealth ark errors before continuing." },
}

function M.derive(status, opts, bridge_status)
  status = status or {}
  opts = opts or {}
  bridge_status = bridge_status or {}

  if status.config_valid == false or status.supported == false then
    return "unsupported"
  end
  if bridge_status.running == true then
    return "update_in_progress"
  end
  local release = status.release or {}
  local metadata = release.installed_metadata
  if metadata and release.product_version and metadata.product_version ~= release.product_version then
    return "restart_required"
  end
  if status.bridge_ready == true and status.repl_ready == true then
    return "live_ready"
  end
  if opts.auto_start_pane == false then
    return "static_only"
  end
  local startup = status.startup or {}
  if startup.phase == "configured" or startup.session_phase == "requested" or startup.session_phase == "bridge_ready" then
    return "static_starting"
  end
  if status.pane_exists == true or status.managed == true then
    return "live_degraded"
  end
  return "static_starting"
end

function M.describe(name)
  return definitions[name] or definitions.unsupported
end

function M.definitions()
  return vim.deepcopy(definitions)
end

return M
