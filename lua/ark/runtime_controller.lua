local M = {}

function M.new(deps)
  vim.validate({
    deps = { deps, "table" },
    console = { deps.console, "table" },
    console_frontend = { deps.console_frontend, "table" },
    ensure_bridge_runtime = { deps.ensure_bridge_runtime, "function" },
    lsp = { deps.lsp, "table" },
    options = { deps.options, "function" },
    session_backend = { deps.session_backend, "table" },
    start_session = { deps.start_session, "function" },
  })

  local readiness_waiters = {}
  local readiness_waiter_seq = 0

  local function options()
    return deps.options()
  end

  local function resolve_bufnr(bufnr)
    if bufnr == nil or bufnr == 0 then
      return vim.api.nvim_get_current_buf()
    end
    return bufnr
  end

  local function is_ark_buffer(bufnr)
    local opts = options()
    return bufnr ~= nil
      and vim.api.nvim_buf_is_valid(bufnr)
      and opts ~= nil
      and vim.b[bufnr].ark_console ~= true
      and vim.tbl_contains(opts.filetypes, vim.bo[bufnr].filetype)
  end

  local function is_ark_runtime_buffer(bufnr)
    local opts = options()
    return bufnr ~= nil
      and vim.api.nvim_buf_is_valid(bufnr)
      and opts ~= nil
      and vim.tbl_contains(opts.filetypes, vim.bo[bufnr].filetype)
  end

  local function is_ark_completion_buffer(bufnr)
    local opts = options()
    return bufnr ~= nil
      and vim.api.nvim_buf_is_valid(bufnr)
      and opts ~= nil
      and (vim.b[bufnr].ark_console == true or vim.tbl_contains(opts.filetypes, vim.bo[bufnr].filetype))
  end

  local function managed_repl_buffer(bufnr)
    return bufnr ~= nil
      and vim.api.nvim_buf_is_valid(bufnr)
      and (vim.b[bufnr].ark_console == true or vim.b[bufnr].ark_terminal == true)
  end

  local function console_view_source_buffer(bufnr)
    local opts = options()
    return bufnr ~= nil
      and vim.api.nvim_buf_is_valid(bufnr)
      and opts ~= nil
      and vim.b[bufnr].ark_console == true
      and vim.tbl_contains(opts.filetypes, vim.bo[bufnr].filetype)
  end

  local function add_candidate_bufnr(candidates, seen, bufnr)
    if type(bufnr) ~= "number" or bufnr < 1 or seen[bufnr] then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    seen[bufnr] = true
    candidates[#candidates + 1] = bufnr
  end

  local function resolve_view_source_bufnr(bufnr)
    if is_ark_buffer(bufnr) then
      return bufnr
    end
    if not managed_repl_buffer(bufnr) then
      return bufnr
    end

    local candidates = {}
    local seen = {}
    add_candidate_bufnr(candidates, seen, vim.b[bufnr].ark_terminal_source_bufnr)
    add_candidate_bufnr(candidates, seen, vim.b[bufnr].ark_console_source_bufnr)
    add_candidate_bufnr(candidates, seen, vim.fn.bufnr("#"))

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(winid) then
        add_candidate_bufnr(candidates, seen, vim.api.nvim_win_get_buf(winid))
      end
    end

    for _, candidate in ipairs(candidates) do
      if is_ark_buffer(candidate) then
        return candidate
      end
    end

    if console_view_source_buffer(bufnr) then
      return bufnr
    end

    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      add_candidate_bufnr(candidates, seen, candidate)
    end

    for _, candidate in ipairs(candidates) do
      if is_ark_buffer(candidate) then
        return candidate
      end
    end

    return nil
  end

  local function runtime_wait_timeout_ms()
    local runtime_config = deps.session_backend.runtime_config(options()) or {}
    return tonumber(runtime_config.bridge_wait_ms or 5000) or 5000
  end

  local function runtime_ready(bufnr)
    if not is_ark_runtime_buffer(bufnr) then
      return false
    end

    local opts = options()
    local session_status = deps.session_backend.status(opts)
    local lsp_status = deps.lsp.status(opts, bufnr)
    local bridge_ready = type(session_status) == "table" and session_status.bridge_ready == true
    local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil

    return bridge_ready
      and type(lsp_status) == "table"
      and lsp_status.available == true
      and lsp_status.sessionBridgeConfigured == true
      and type(detached_status) == "table"
      and detached_status.lastSessionUpdateStatus == "ready"
  end

  local function live_lsp_client_attached(bufnr)
    local opts = options()
    if type(bufnr) ~= "number" or not opts or type(opts.lsp) ~= "table" then
      return false
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return false
    end

    for _, client in ipairs(vim.lsp.get_clients({ name = opts.lsp.name, bufnr = bufnr })) do
      if client.initialized == true and not (client.is_stopped and client:is_stopped()) then
        return true
      end
    end

    return false
  end

  local function active_console_status(bufnr)
    if not console_view_source_buffer(bufnr) then
      return nil
    end

    local status = deps.console.status(bufnr)
    if type(status) ~= "table" or status.running ~= true then
      return nil
    end
    if type(status.session_id) ~= "string" or status.session_id == "" then
      return nil
    end
    if type(status.status_path) ~= "string" or status.status_path == "" then
      return nil
    end

    return status
  end

  local function resolve_explicit_help_bufnr(bufnr)
    bufnr = resolve_bufnr(bufnr)
    if is_ark_buffer(bufnr) or active_console_status(bufnr) then
      return bufnr
    end

    local source_bufnr = resolve_view_source_bufnr(bufnr)
    if type(source_bufnr) == "number" and vim.api.nvim_buf_is_valid(source_bufnr) then
      return source_bufnr
    end

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_is_valid(winid) then
        local candidate = vim.api.nvim_win_get_buf(winid)
        if is_ark_buffer(candidate) then
          return candidate
        end
      end
    end

    for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
      if is_ark_buffer(candidate) then
        return candidate
      end
    end

    return bufnr
  end

  local function console_runtime_ready(bufnr)
    if not active_console_status(bufnr) then
      return false
    end

    local lsp_status = deps.lsp.status(options(), bufnr)
    local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil

    return type(lsp_status) == "table"
      and lsp_status.available == true
      and lsp_status.sessionBridgeConfigured == true
      and type(detached_status) == "table"
      and detached_status.lastSessionUpdateStatus == "ready"
  end

  local function repl_ready()
    local status = deps.session_backend.status(options())
    return type(status) == "table" and status.repl_ready == true
  end

  local function wait_for_repl_ready_for_send()
    local opts = options()
    local runtime_config = deps.session_backend.runtime_config(opts) or {}
    if deps.console_frontend.normalize(runtime_config.console_frontend) == "nvim-console" then
      local function console_ready()
        return deps.session_backend.console_ready(opts) == true
      end

      if console_ready() then
        return true, nil
      end

      if vim.wait(runtime_wait_timeout_ms(), console_ready, 50, false) then
        return true, nil
      end

      return nil, "managed nvim-console RPC endpoint is not ready for send"
    end

    if repl_ready() then
      return true, nil
    end

    if vim.wait(runtime_wait_timeout_ms(), repl_ready, 50, false) then
      return true, nil
    end

    return nil, "managed R repl is not ready for send"
  end

  local function readiness_bucket(kind, bufnr, create)
    local group = readiness_waiters[kind]
    if type(group) ~= "table" then
      if not create then
        return nil
      end
      group = {}
      readiness_waiters[kind] = group
    end

    local bucket = group[bufnr]
    if type(bucket) ~= "table" then
      if not create then
        return nil
      end
      bucket = {}
      group[bufnr] = bucket
    end

    return bucket, group
  end

  local function remove_ready_waiter(waiter)
    local bucket, group = readiness_bucket(waiter.kind, waiter.bufnr, false)
    if type(bucket) ~= "table" or bucket[waiter.id] ~= waiter then
      return false
    end

    bucket[waiter.id] = nil
    if next(bucket) == nil then
      group[waiter.bufnr] = nil
    end
    if next(group) == nil then
      readiness_waiters[waiter.kind] = nil
    end
    return true
  end

  local function run_ready_callback(waiter, err)
    vim.schedule(function()
      if type(waiter.callback) == "function" then
        waiter.callback(err)
      end
    end)
  end

  local function drain_ready_waiters(kind, bufnr)
    local bucket, group = readiness_bucket(kind, bufnr, false)
    if type(bucket) ~= "table" then
      return
    end

    local drained = {}
    for id, waiter in pairs(bucket) do
      if type(waiter.ready) == "function" and waiter.ready() then
        bucket[id] = nil
        drained[#drained + 1] = waiter
      end
    end

    if next(bucket) == nil then
      group[bufnr] = nil
    end
    if next(group) == nil then
      readiness_waiters[kind] = nil
    end

    for _, waiter in ipairs(drained) do
      run_ready_callback(waiter, nil)
    end
  end

  local function drain_all_ready_waiters(bufnr)
    local kinds = {}
    for kind, _ in pairs(readiness_waiters) do
      kinds[#kinds + 1] = kind
    end

    for _, kind in ipairs(kinds) do
      drain_ready_waiters(kind, bufnr)
    end
  end

  local function wait_until_ready(kind, bufnr, label, ready, timeout_message, callback)
    if ready() then
      local result, err = callback(nil)
      return result, err, "callback"
    end

    readiness_waiter_seq = readiness_waiter_seq + 1
    local waiter = {
      id = readiness_waiter_seq,
      kind = kind,
      bufnr = bufnr,
      label = label,
      ready = ready,
      timeout_message = timeout_message,
      callback = callback,
    }

    local bucket = readiness_bucket(kind, bufnr, true)
    bucket[waiter.id] = waiter

    vim.defer_fn(function()
      if not remove_ready_waiter(waiter) then
        return
      end

      if ready() then
        run_ready_callback(waiter, nil)
        return
      end

      run_ready_callback(waiter, timeout_message)
    end, runtime_wait_timeout_ms())

    return true, nil, "queued"
  end

  local function wait_until_runtime_ready(bufnr, label, callback)
    return wait_until_ready("runtime", bufnr, label, function()
      return runtime_ready(bufnr)
    end, label .. " bridge is not ready", callback)
  end

  local function wait_until_console_runtime_ready(bufnr, label, callback)
    return wait_until_ready("runtime", bufnr, label, function()
      return console_runtime_ready(bufnr)
    end, label .. " console session is not ready", callback)
  end

  local function wait_until_repl_ready(bufnr, label, callback)
    return wait_until_ready("repl", bufnr, label, repl_ready, "managed R repl is not ready for help", callback)
  end

  local function ensure_runtime_ready(bufnr, label)
    local opts = options()
    bufnr = resolve_bufnr(bufnr)
    label = label or "ark.nvim runtime"

    if not is_ark_runtime_buffer(bufnr) then
      return nil, label .. " requires an R-family buffer"
    end

    deps.lsp.start(opts, bufnr)

    local bridge_ok, bridge_err = deps.ensure_bridge_runtime({
      user_initiated = true,
      wait_on_pending = true,
    })
    if not bridge_ok then
      return nil, bridge_err
    end

    local _, pane_err = deps.start_session({
      recover_bridge_failure = true,
    })
    if pane_err then
      return nil, pane_err
    end

    deps.lsp.sync_sessions(opts, bufnr)

    local runtime_config = deps.session_backend.runtime_config(opts) or {}
    local timeout_ms = tonumber(runtime_config.bridge_wait_ms or 5000) or 5000
    if not vim.wait(timeout_ms, function()
      return runtime_ready(bufnr)
    end, 100, false) then
      return nil, label .. " bridge is not ready"
    end

    return true
  end

  local function with_managed_session_ready(bufnr, label, callback, runtime_opts)
    runtime_opts = runtime_opts or {}
    local opts = options()
    bufnr = resolve_bufnr(bufnr)
    label = label or "ark.nvim runtime"
    local wait_until = runtime_opts.wait_until_ready or wait_until_runtime_ready

    if not is_ark_runtime_buffer(bufnr) then
      return nil, label .. " requires an R-family buffer", "runtime"
    end

    local callback_done = false
    local function done(err)
      if callback_done then
        return
      end
      callback_done = true
      return callback(err)
    end

    if live_lsp_client_attached(bufnr) and runtime_ready(bufnr) then
      local result, err = done(nil)
      return result, err, "callback"
    end

    local function finish_after_bridge()
      if not is_ark_runtime_buffer(bufnr) then
        return nil, label .. " requires an R-family buffer", "runtime"
      end

      local pane_id, pane_err = deps.start_session({
        recover_bridge_failure = true,
      })
      if not pane_id then
        return nil, pane_err or "failed to start managed R pane", "runtime"
      end

      deps.lsp.sync_sessions(opts, bufnr)
      local result, err, err_source = wait_until(bufnr, label, done)
      if err_source == "queued" then
        vim.defer_fn(function()
          drain_all_ready_waiters(bufnr)
        end, 50)
      end
      return result, err, err_source
    end

    if runtime_opts.start_lsp ~= false then
      deps.lsp.start(opts, bufnr)
    end

    local bridge_complete = false
    local bridge_ok, bridge_err, bridge_kind = deps.ensure_bridge_runtime({
      user_initiated = true,
      wait_on_pending = false,
      on_build_complete = function(result)
        if bridge_complete then
          return
        end
        bridge_complete = true

        vim.schedule(function()
          if type(result) == "table" and result.ok == true then
            if runtime_opts.start_lsp ~= false then
              deps.lsp.start(opts, bufnr)
            end
            local ok, err, err_source = finish_after_bridge()
            if not ok and err and err_source ~= "callback" then
              done(err)
            end
            return
          end

          local failure = type(result) == "table" and result.error or nil
          done(failure or bridge_err or "arkbridge runtime install failed")
        end)
      end,
    })

    if bridge_ok then
      bridge_complete = true
      return finish_after_bridge()
    end

    if bridge_kind == "build_pending" then
      vim.defer_fn(function()
        if bridge_complete then
          return
        end
        bridge_complete = true
        done(bridge_err or "arkbridge runtime install did not finish")
      end, 20000)
      return true, nil, "queued"
    end

    return nil, bridge_err, "runtime"
  end

  local function with_console_session_ready(bufnr, label, callback, runtime_opts)
    runtime_opts = runtime_opts or {}
    local opts = options()
    bufnr = resolve_bufnr(bufnr)
    label = label or "ark.nvim runtime"
    local wait_until = runtime_opts.wait_until_ready or wait_until_console_runtime_ready
    local request_bufnr = runtime_opts.request_bufnr

    if not active_console_status(bufnr) then
      return nil, label .. " requires a running Ark console", "runtime"
    end

    local callback_done = false
    local function done(err)
      if callback_done then
        return
      end
      callback_done = true
      return callback(err)
    end

    if runtime_opts.start_lsp ~= false then
      deps.lsp.start(opts, bufnr)
      if type(request_bufnr) == "number" and request_bufnr ~= bufnr and vim.api.nvim_buf_is_valid(request_bufnr) then
        deps.lsp.start(opts, request_bufnr)
      end
    end

    deps.lsp.sync_sessions(opts, bufnr)

    local result, err, err_source = wait_until(bufnr, label, done)
    if err_source == "queued" then
      vim.defer_fn(function()
        drain_all_ready_waiters(bufnr)
      end, 50)
    end
    return result, err, err_source
  end

  return {
    active_console_status = active_console_status,
    add_candidate_bufnr = add_candidate_bufnr,
    console_runtime_ready = console_runtime_ready,
    drain_all_ready_waiters = drain_all_ready_waiters,
    ensure_runtime_ready = ensure_runtime_ready,
    is_ark_buffer = is_ark_buffer,
    is_ark_completion_buffer = is_ark_completion_buffer,
    is_ark_runtime_buffer = is_ark_runtime_buffer,
    repl_ready = repl_ready,
    resolve_bufnr = resolve_bufnr,
    resolve_explicit_help_bufnr = resolve_explicit_help_bufnr,
    resolve_view_source_bufnr = resolve_view_source_bufnr,
    runtime_ready = runtime_ready,
    wait_for_repl_ready_for_send = wait_for_repl_ready_for_send,
    wait_until_console_runtime_ready = wait_until_console_runtime_ready,
    wait_until_repl_ready = wait_until_repl_ready,
    wait_until_runtime_ready = wait_until_runtime_ready,
    with_console_session_ready = with_console_session_ready,
    with_managed_session_ready = with_managed_session_ready,
    with_runtime_ready = with_managed_session_ready,
  }
end

return M
