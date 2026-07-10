vim.opt.rtp:prepend(vim.fn.getcwd())

local startup_state = require("ark.startup_state")

local state = {
  generation = 3,
  invalid_transition_count = 0,
  lsp_phase = "starting",
  phase = "managed_session_requested",
  session_phase = "requested",
}

local ok, err = startup_state.transition(state, "repl_ready", { generation = 3 })
assert(ok == nil, "REPL readiness must be rejected before bridge readiness")
assert(type(err) == "string" and err:find("bridge readiness", 1, true), err)
assert(state.session_phase == "requested", "invalid transition mutated the session phase")
assert(state.invalid_transition_count == 1, "invalid transition was not recorded")

assert(startup_state.transition(state, "bridge_ready", { generation = 3 }))
assert(state.phase == "bridge_ready")
assert(startup_state.transition(state, "repl_ready", { generation = 3 }))
assert(state.phase == "repl_ready")
assert(startup_state.transition(state, "lsp_initialized", { generation = 3 }))
assert(startup_state.transition(state, "static_ready", { generation = 3 }))
assert(startup_state.transition(state, "live_hydrated", { generation = 3 }))
assert(state.phase == "live_hydrated")

local previous_event = state.last_event
ok, err = startup_state.transition(state, "degraded", {
  generation = 2,
  error = "stale failure",
})
assert(ok == nil, "stale generations must be rejected")
assert(type(err) == "string" and err:find("stale startup transition", 1, true), err)
assert(state.last_event == previous_event, "stale transition replaced the authoritative event")
assert(state.phase == "live_hydrated", "stale transition replaced the authoritative phase")

assert(startup_state.transition(state, "stopping", { generation = 3 }))
assert(state.phase == "stopping")
assert(startup_state.transition(state, "stopped", { generation = 3 }))
assert(state.phase == "stopped")
