local M = {}

local definitions = {
  live_ready = { works = "static and live language features", action = nil },
  live_busy = { works = "static language features", action = "Wait for R to finish; interrupt explicitly in the console if needed." },
  static_starting = { works = "static language features", action = nil },
  static_only = { works = "static language features", action = "Check :Ark status when live features are needed." },
  live_degraded = { works = "static language features", action = "Inspect :Ark status and the console; a timeout does not prove R has stopped." },
  update_in_progress = { works = "existing static features", action = "Wait for installation to finish." },
  restart_required = { works = "static language features", action = "Run :Ark pane restart, then :Ark refresh." },
  unsupported = { works = "no supported guarantee", action = "Fix :checkhealth ark errors before continuing." },
}

function M.activity(status)
  status = status or {}
  local startup = type(status.startup_status) == "table" and status.startup_status or {}
  if require("ark.session_runtime").console_busy(startup) then
    return { kind = "user_code", detail = "R is executing submitted code; live queries are deferred." }
  end
  local lsp = type(status.lsp_status) == "table" and status.lsp_status or {}
  local bridge = type(lsp.sessionBridge) == "table" and lsp.sessionBridge or {}
  local runtime = type(bridge.runtime) == "table" and bridge.runtime or {}
  if type(runtime.activeOperation) == "table" then
    return { kind = "ark_request", detail = "An Ark bridge request is in progress." }
  end
  if status.bridge_ready == true then
    return { kind = "ready", detail = "The bridge answered; REPL input readiness is reported separately." }
  end
  if status.pane_exists == false or (tonumber(startup.pid) and not require("ark.session_runtime").status_pid_alive(startup.pid)) then
    return { kind = "disconnected", detail = "The managed pane or R process is no longer present." }
  end
  if status.pane_exists == true or startup.status == "ready" then
    return { kind = "unresponsive", detail = "The bridge has not answered; the cause is unknown." }
  end
  return { kind = "unavailable", detail = "No live runtime evidence is available yet." }
end

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
  local activity = M.activity(status)
  if activity.kind == "user_code" or activity.kind == "ark_request" then
    return "live_busy"
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
