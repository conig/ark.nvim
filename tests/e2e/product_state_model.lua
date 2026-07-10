local state = require("ark.product_state")

local cases = {
  { "unsupported", { config_valid = false }, {}, {} },
  { "update_in_progress", {}, {}, { running = true } },
  {
    "restart_required",
    { release = { product_version = "2", installed_metadata = { product_version = "1" } } },
    {},
    {},
  },
  { "static_only", {}, { auto_start_pane = false }, {} },
  { "live_ready", { bridge_ready = true, repl_ready = true }, { auto_start_pane = false }, {} },
  { "live_ready", { bridge_ready = true, repl_ready = true }, { auto_start_pane = true }, {} },
  {
    "static_starting",
    { startup = { session_phase = "requested" } },
    { auto_start_pane = true },
    {},
  },
  { "live_degraded", { managed = true }, { auto_start_pane = true }, {} },
}

for _, case in ipairs(cases) do
  local expected, status, opts, bridge = unpack(case)
  assert(state.derive(status, opts, bridge) == expected, vim.inspect(case))
  local description = state.describe(expected)
  assert(type(description.works) == "string" and description.works ~= "")
end
