local uv = vim.uv or vim.loop

local M = {}

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function wallclock_ms()
  if uv and type(uv.gettimeofday) == "function" then
    local sec, usec = uv.gettimeofday()
    if type(sec) == "number" and type(usec) == "number" then
      return (sec * 1000) + math.floor(usec / 1000)
    end
  end

  return math.floor(os.time() * 1000)
end

local function iso_timestamp(ms)
  if type(ms) ~= "number" then
    return nil
  end

  local sec = math.floor(ms / 1000)
  local millis = ms - (sec * 1000)
  return os.date("%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03d", millis)
end

local function format_ms(value)
  if type(value) ~= "number" then
    return nil
  end

  return string.format("+%dms", math.max(0, math.floor(value)))
end

local function derive_phase(state)
  if state.session_phase == "stopping" or state.session_phase == "stopped" then
    return state.session_phase
  end
  if state.session_phase == "restarting" then
    return "restarting"
  end
  if state.lsp_phase == "live_hydrated" then
    return "live_hydrated"
  end
  if state.session_phase == "degraded" then
    return "degraded_static_only"
  end
  if state.session_phase == "repl_ready" then
    return "repl_ready"
  end
  if state.session_phase == "bridge_ready" then
    return "bridge_ready"
  end
  if state.session_phase == "bridge_installing" then
    return "bridge_installing"
  end
  if state.session_phase == "requested" then
    return "managed_session_requested"
  end
  if state.lsp_phase == "static_ready" then
    return "static_ready"
  end
  if state.lsp_phase == "initialized" then
    return "lsp_initialized"
  end
  if state.lsp_phase == "starting" then
    return "lsp_starting"
  end
  return "configured"
end

local function invalid(state, event, message)
  state.invalid_transition_count = (state.invalid_transition_count or 0) + 1
  state.last_invalid_transition = {
    event = event,
    message = message,
  }
  return nil, message
end

local function set_event(state, event)
  state.phase = derive_phase(state)
  state.last_event = event
  state.last_transition_ms = wallclock_ms()
  return true
end

function M.transition(state, event, details)
  details = details or {}
  if type(state) ~= "table" then
    return nil, "startup state is missing"
  end
  if details.generation ~= nil and details.generation ~= state.generation then
    return invalid(state, event, string.format(
      "stale startup transition generation %s (current %s)",
      tostring(details.generation),
      tostring(state.generation)
    ))
  end

  if event == "lsp_initialized" then
    if state.lsp_phase ~= "starting" then
      return invalid(state, event, "LSP can only initialize after it starts")
    end
    state.lsp_phase = "initialized"
  elseif event == "static_ready" then
    if state.lsp_phase ~= "starting" and state.lsp_phase ~= "initialized" then
      return invalid(state, event, "static analysis can only become ready after LSP startup")
    end
    state.lsp_phase = "static_ready"
  elseif event == "bridge_installing" then
    if state.session_phase ~= "requested" and state.session_phase ~= "restarting" then
      return invalid(state, event, "bridge installation requires a requested or restarting session")
    end
    state.session_phase = "bridge_installing"
  elseif event == "bridge_ready" then
    if state.session_phase ~= "requested"
      and state.session_phase ~= "bridge_installing"
      and state.session_phase ~= "degraded"
      and state.session_phase ~= "restarting"
    then
      return invalid(state, event, "bridge readiness requires an active managed-session request")
    end
    state.session_phase = "bridge_ready"
    state.last_error = nil
  elseif event == "repl_ready" then
    if state.session_phase ~= "bridge_ready" and state.session_phase ~= "repl_ready" then
      return invalid(state, event, "REPL readiness requires bridge readiness")
    end
    state.session_phase = "repl_ready"
  elseif event == "live_hydrated" then
    if state.session_phase ~= "repl_ready" then
      return invalid(state, event, "live LSP hydration requires REPL readiness")
    end
    if state.lsp_phase ~= "starting"
      and state.lsp_phase ~= "initialized"
      and state.lsp_phase ~= "static_ready"
      and state.lsp_phase ~= "live_hydrated"
    then
      return invalid(state, event, "live LSP hydration requires an active LSP")
    end
    state.lsp_phase = "live_hydrated"
  elseif event == "degraded" then
    state.session_phase = "degraded"
    state.last_error = details.error
  elseif event == "stopping" then
    state.session_phase = "stopping"
  elseif event == "stopped" then
    if state.session_phase ~= "stopping" then
      return invalid(state, event, "a managed session can only stop after entering stopping state")
    end
    state.session_phase = "stopped"
    state.lsp_phase = "stopped"
  elseif event == "restarting" then
    if state.session_phase == "stopping" or state.session_phase == "stopped" then
      return invalid(state, event, "a stopped session must be requested again before restart")
    end
    state.session_phase = "restarting"
  else
    return invalid(state, event, "unknown startup transition: " .. tostring(event))
  end

  return set_event(state, event)
end

function M.new(deps)
  deps = deps or {}
  local states = {}
  local generations = {}

  local controller = {}

  local function options()
    return type(deps.options) == "function" and deps.options() or nil
  end

  local function tracked_file(bufnr)
    local path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
    return path ~= "" and path or nil
  end

  local function startup_log_path()
    local opts = options()
    local runtime_config = deps.session_backend.runtime_config(opts)
    if type(runtime_config) ~= "table" then
      return nil
    end

    local status = deps.session_backend.startup_status_authoritative(opts)
    if type(status) ~= "table" then
      return nil
    end
    return type(status.log_path) == "string" and status.log_path or nil
  end

  local function append_log(event, fields)
    local path = startup_log_path()
    if type(path) ~= "string" or path == "" then
      return nil
    end

    local elapsed_ms = nil
    for _, field in ipairs(fields or {}) do
      if type(field) == "table" and field.key == "startup_elapsed_ms" and type(field.value) == "number" then
        elapsed_ms = field.value
        break
      end
    end

    local ts = iso_timestamp(wallclock_ms())
    local elapsed = format_ms(elapsed_ms)
    local line = elapsed and string.format("[%s %s] [nvim-startup] %s", ts, elapsed, event)
      or string.format("[%s] [nvim-startup] %s", ts, event)
    for _, field in ipairs(fields or {}) do
      if type(field) == "table" and type(field.key) == "string" and field.key ~= "" and field.value ~= nil then
        local rendered = field.value
        if type(rendered) == "number" and field.key:sub(-3) == "_ms" then
          rendered = format_ms(rendered)
        end
        line = line .. string.format(" %s=%s", field.key, tostring(rendered))
      end
    end

    local dir = vim.fs.dirname(path)
    if type(dir) == "string" and dir ~= "" then
      vim.fn.mkdir(dir, "p")
    end
    vim.fn.writefile({ line }, path, "a")
    return path
  end

  local function cleanup(bufnr)
    states[bufnr] = nil
  end

  local function ensure_cleanup(bufnr)
    local state = states[bufnr]
    if not state or state.cleanup_registered == true then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      cleanup(bufnr)
      return
    end

    state.cleanup_registered = true
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      buffer = bufnr,
      once = true,
      callback = function()
        cleanup(bufnr)
      end,
    })
  end

  function controller:begin(bufnr)
    local opts = options() or {}
    local generation = (generations[bufnr] or 0) + 1
    generations[bufnr] = generation
    local started_at_ms = wallclock_ms()
    states[bufnr] = {
      bufnr = bufnr,
      cleanup_registered = false,
      file = tracked_file(bufnr),
      filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil,
      generation = generation,
      invalid_transition_count = 0,
      last_event = "configured",
      lsp_phase = opts.auto_start_lsp == true and "starting" or "disabled",
      log_path = startup_log_path(),
      main_buffer_unlocked = false,
      phase = "configured",
      session_phase = opts.auto_start_pane == true and "requested" or "disabled",
      started_at_iso = iso_timestamp(started_at_ms),
      started_at_ms = started_at_ms,
      started_mono_ms = monotonic_ms(),
    }
    states[bufnr].phase = derive_phase(states[bufnr])
    ensure_cleanup(bufnr)
    return generation
  end

  function controller:is_current(bufnr, generation)
    return generations[bufnr] == generation and states[bufnr] ~= nil
  end

  function controller:unlocked(bufnr)
    local state = states[bufnr]
    if type(state) ~= "table" then
      return true
    end
    if generations[bufnr] ~= state.generation then
      cleanup(bufnr)
      return true
    end
    return state.main_buffer_unlocked == true
  end

  function controller:transition(bufnr, event, details)
    local state = states[bufnr]
    if type(state) ~= "table" then
      return nil, "startup state is not tracked for buffer " .. tostring(bufnr)
    end
    return M.transition(state, event, details)
  end

  function controller:observe(bufnr)
    local state = states[bufnr]
    local opts = options()
    if type(state) ~= "table" or type(opts) ~= "table" then
      return false, nil, nil
    end
    if not vim.api.nvim_buf_is_valid(bufnr)
      or not vim.tbl_contains(opts.filetypes or {}, vim.bo[bufnr].filetype)
    then
      return false, nil, nil
    end

    local backend_snapshot = nil
    if opts.auto_start_pane == true then
      backend_snapshot = deps.session_backend.startup_snapshot(opts, {
        include_prompt_ready = false,
        validate_bridge = false,
      })
      local status = type(backend_snapshot) == "table" and backend_snapshot.startup_status or nil
      if type(backend_snapshot) ~= "table" or backend_snapshot.bridge_ready ~= true then
        return false, backend_snapshot, nil
      end
      if state.session_phase ~= "bridge_ready" and state.session_phase ~= "repl_ready" then
        self:transition(bufnr, "bridge_ready")
      end
      if type(status) ~= "table" or status.repl_ready ~= true then
        return false, backend_snapshot, nil
      end
      if state.session_phase ~= "repl_ready" then
        self:transition(bufnr, "repl_ready")
      end
    end

    if opts.auto_start_lsp ~= true then
      return true, backend_snapshot, nil
    end

    local lsp_status = deps.lsp.status(opts, bufnr, {
      cache_ttl_ms = 50,
      throttle_ms = 25,
      timeout_ms = 50,
    })
    if type(lsp_status) ~= "table" or lsp_status.available ~= true then
      return false, backend_snapshot, lsp_status
    end
    if state.lsp_phase == "starting" then
      self:transition(bufnr, "lsp_initialized")
      self:transition(bufnr, "static_ready")
    elseif state.lsp_phase == "initialized" then
      self:transition(bufnr, "static_ready")
    end
    if opts.auto_start_pane ~= true then
      return true, backend_snapshot, lsp_status
    end

    local detached = type(lsp_status.detachedSessionStatus) == "table" and lsp_status.detachedSessionStatus or nil
    local hydrated = type(detached) == "table"
      and detached.lastSessionUpdateStatus == "ready"
      and type(detached.lastBootstrapSuccessMs) == "number"
    if hydrated and state.lsp_phase ~= "live_hydrated" then
      self:transition(bufnr, "live_hydrated")
    end
    return hydrated, backend_snapshot, lsp_status
  end

  function controller:record_unlock(bufnr, source, unlock_opts)
    local state = states[bufnr]
    if type(state) ~= "table" or state.main_buffer_unlocked == true then
      return
    end
    if generations[bufnr] ~= state.generation then
      cleanup(bufnr)
      return
    end

    unlock_opts = unlock_opts or {}
    local unlocked_at_ms = wallclock_ms()
    state.file = state.file or tracked_file(bufnr)
    state.filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or state.filetype
    state.log_path = startup_log_path() or state.log_path
    state.main_buffer_unlocked = true
    state.main_buffer_unlock_at_iso = iso_timestamp(unlocked_at_ms)
    state.main_buffer_unlock_at_ms = unlocked_at_ms
    state.main_buffer_unlock_elapsed_ms = math.max(0, monotonic_ms() - state.started_mono_ms)
    state.main_buffer_unlock_source = source or "SafeState"
    if type(unlock_opts.post_lsp_bootstrap_unlock_ms) == "number" then
      state.post_lsp_bootstrap_unlock_ms = math.max(0, unlock_opts.post_lsp_bootstrap_unlock_ms)
    end

    state.log_path = append_log("main_buffer_unlocked", {
      { key = "bufnr", value = bufnr },
      { key = "filetype", value = state.filetype },
      { key = "file", value = state.file },
      { key = "startup_elapsed_ms", value = state.main_buffer_unlock_elapsed_ms },
      { key = "post_lsp_bootstrap_unlock_ms", value = state.post_lsp_bootstrap_unlock_ms },
      { key = "source", value = state.main_buffer_unlock_source },
    }) or state.log_path
  end

  function controller:mark_safe(bufnr, source)
    if self:unlocked(bufnr) then
      return
    end
    local ready, _, lsp_status = self:observe(bufnr)
    if not ready then
      return
    end

    local post_lsp_bootstrap_unlock_ms = nil
    local detached = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
    if type(detached) == "table" and type(detached.lastBootstrapSuccessMs) == "number" then
      post_lsp_bootstrap_unlock_ms = math.max(0, wallclock_ms() - detached.lastBootstrapSuccessMs)
    end
    self:record_unlock(bufnr, source, {
      post_lsp_bootstrap_unlock_ms = post_lsp_bootstrap_unlock_ms,
    })
  end

  function controller:mark_live_hydrated(bufnr, source)
    self:observe(bufnr)
    local state = states[bufnr]
    if type(state) == "table" and state.session_phase == "repl_ready" and state.lsp_phase ~= "live_hydrated" then
      self:transition(bufnr, "live_hydrated")
    end
    self:record_unlock(bufnr, source or "LspBootstrap", {
      post_lsp_bootstrap_unlock_ms = 0,
    })
    return true
  end

  function controller:status(bufnr)
    if type(bufnr) ~= "number" then
      bufnr = vim.api.nvim_get_current_buf()
    end
    if #vim.api.nvim_list_uis() == 0 then
      self:mark_safe(bufnr, "HeadlessStatusPoll")
    end

    local state = states[bufnr]
    if type(state) ~= "table" then
      return {
        tracked = false,
        bufnr = bufnr,
        file = tracked_file(bufnr),
        filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil,
        log_path = startup_log_path(),
        main_buffer_unlocked = false,
        phase = "configured",
      }
    end

    local out = vim.deepcopy(state)
    out.tracked = true
    out.cleanup_registered = nil
    out.started_mono_ms = nil
    out.log_path = out.log_path or startup_log_path()
    return out
  end

  return controller
end

return M
