local blink = require("ark.blink")
local bridge = require("ark.bridge")
local config = require("ark.config")
local console = require("ark.console")
local console_frontend = require("ark.console_frontend")
local dev = require("ark.dev")
local expression = require("ark.expression")
local help_render = require("ark.help_render")
local keymaps = require("ark.keymaps")
local lsp = require("ark.lsp")
local notifications = require("ark.notifications")
local product_state = require("ark.product_state")
local release = require("ark.release")
local session_backend = require("ark.session")
local snippets = require("ark.snippets")
local startup_state = require("ark.startup_state")
local target_actions_module = require("ark.target_actions")
local target_view = require("ark.target_view")
local target_tools = require("ark.targets")
local view = require("ark.view")
local view_popup_backend = require("ark.view_popup_backend")

local M = {}

local did_setup = false
local options = nil
local readiness_waiters = {}
local readiness_waiter_seq = 0
local pending_session_sync = 0
local target_actions = nil
local help_rpc_fn = "__ark_nvim_help_rpc"
local view_rpc_fn = "__ark_nvim_view_rpc"
local is_ark_buffer
local is_ark_runtime_buffer
local runtime_ready
local repl_ready
local ensure_bridge_runtime
local start_or_recover_pane_after_runtime_ready
local tar_read_target_name

local startup = startup_state.new({
  lsp = lsp,
  options = function()
    return options
  end,
  session_backend = session_backend,
})

local help_expression = help_render.expression
local help_popup_payload = help_render.help_popup_payload
local normalize_help_display = help_render.normalize_help_display
local normalize_view_display = help_render.normalize_view_display
local open_readonly_float = help_render.open_readonly_float
local r_string_literal = help_render.r_string_literal

local function should_use_tmux_help_popup()
  local help_opts = type(options) == "table" and type(options.help) == "table" and options.help or {}
  local display = normalize_help_display(help_opts.display)
  if display == "float" then
    return false
  end
  if display == "tmux_popup" then
    return true
  end

  local backend_name = type(session_backend.backend_name) == "function" and session_backend.backend_name(options) or "tmux"
  if backend_name ~= "tmux" then
    return false
  end

  local status = type(session_backend.status) == "function" and session_backend.status(options) or nil
  return type(status) == "table" and status.inside_tmux == true
end

local current_nvim_server
local help_popup_backend_rpc_name = "__ark_help_popup_backend"
local help_popup_backend_seq = 0
local help_popup_backends = {}

local function help_popup_backend_response(ok, value, err)
  return {
    ok = ok == true,
    value = value,
    err = err,
  }
end

local function ensure_help_popup_backend_rpc()
  _G[help_popup_backend_rpc_name] = function(backend_id, method, args)
    if type(backend_id) ~= "string" or backend_id == "" then
      return help_popup_backend_response(false, nil, "ArkHelp popup backend id is required")
    end

    if method == "dispose" then
      help_popup_backends[backend_id] = nil
      return help_popup_backend_response(true, true, nil)
    end

    local backend = help_popup_backends[backend_id]
    if type(backend) ~= "table" then
      return help_popup_backend_response(false, nil, "unknown ArkHelp popup backend: " .. tostring(backend_id))
    end

    if method ~= "page" then
      return help_popup_backend_response(false, nil, "unsupported ArkHelp popup backend method: " .. tostring(method))
    end

    args = type(args) == "table" and args or {}
    local topic = args[1]
    if type(topic) ~= "string" or topic == "" then
      return help_popup_backend_response(false, nil, "ArkHelp popup link requires a non-empty topic")
    end

    local bufnr = backend.source_bufnr
    if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
      bufnr = 0
    end

    local page, page_err = lsp.help_text(options, bufnr, topic)
    if not page then
      return help_popup_backend_response(false, nil, page_err or "no help text found")
    end

    return help_popup_backend_response(true, help_popup_payload(page.text, page.references, topic), nil)
  end
end

local function register_help_popup_backend(source_bufnr)
  local server = current_nvim_server()
  if type(server) ~= "string" or server == "" then
    return nil
  end

  ensure_help_popup_backend_rpc()
  help_popup_backend_seq = help_popup_backend_seq + 1
  local backend_id = "ark-help-popup-" .. tostring(vim.fn.getpid()) .. "-" .. tostring(help_popup_backend_seq)
  help_popup_backends[backend_id] = {
    source_bufnr = source_bufnr,
  }

  return {
    server = server,
    backend_id = backend_id,
    rpc_name = help_popup_backend_rpc_name,
  }
end

local function open_help_popup(page, topic, source_bufnr)
  local help_opts = type(options) == "table" and type(options.help) == "table" and options.help or {}
  local payload = help_popup_payload(page.text, page.references, topic)
  local popup_opts = vim.tbl_deep_extend("force", help_opts.popup or {}, {
    title = payload.title,
  })
  local backend = register_help_popup_backend(source_bufnr)
  if backend then
    popup_opts.help = vim.tbl_extend("force", backend, {
      initial = {
        topic = payload.topic,
        references = payload.references,
      },
    })
  end

  return session_backend.help_popup(options, table.concat(payload.lines, "\n"), popup_opts)
end

local function should_use_tmux_view_popup()
  local view_opts = type(options) == "table" and type(options.view) == "table" and options.view or {}
  local display = normalize_view_display(view_opts.display)
  if display == "tab" then
    return false
  end
  if display == "tmux_popup" then
    return true
  end

  local backend_name = type(session_backend.backend_name) == "function" and session_backend.backend_name(options) or "tmux"
  if backend_name ~= "tmux" then
    return false
  end

  local status = type(session_backend.status) == "function" and session_backend.status(options) or nil
  return type(status) == "table" and status.inside_tmux == true
end

current_nvim_server = function()
  if type(vim.v.servername) == "string" and vim.v.servername ~= "" then
    return vim.v.servername
  end
  if type(vim.fn.serverstart) ~= "function" then
    return nil
  end

  local ok, server = pcall(vim.fn.serverstart)
  if ok and type(server) == "string" and server ~= "" then
    return server
  end
  if type(vim.v.servername) == "string" and vim.v.servername ~= "" then
    return vim.v.servername
  end

  return nil
end

local function open_view_tmux_popup(expr, source_bufnr, server)
  if not should_use_tmux_view_popup() then
    return nil, nil
  end

  server = server or current_nvim_server()
  if type(server) ~= "string" or server == "" then
    return nil, "tmux ArkView popup requires this Neovim instance to have an RPC server"
  end

  local backend_id, backend_err = view_popup_backend.register({
    options = options,
    source_bufnr = source_bufnr,
  })
  if not backend_id then
    return nil, backend_err
  end

  local view_opts = type(options) == "table" and type(options.view) == "table" and options.view or {}
  local popup_opts = vim.tbl_deep_extend("force", view_opts.popup or {}, {
    title = "ArkView: " .. expr,
  })
  local popup_ok, popup_err = session_backend.view_popup(options, server, backend_id, expr, popup_opts)
  if not popup_ok then
    view_popup_backend.unregister(backend_id)
    return nil, popup_err or "failed to open tmux ArkView popup"
  end

  return true, nil
end

local function wait_for_help_runtime(bufnr)
  local runtime_config = session_backend.runtime_config(options) or {}
  local timeout_ms = tonumber(runtime_config.bridge_wait_ms or 5000) or 5000

  return vim.wait(timeout_ms, function()
    return runtime_ready(bufnr)
  end, 100, false)
end

local function resolve_bufnr(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function managed_repl_buffer(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and (vim.b[bufnr].ark_console == true or vim.b[bufnr].ark_terminal == true)
end

local function console_view_source_buffer(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and options ~= nil
    and vim.b[bufnr].ark_console == true
    and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
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
  local runtime_config = session_backend.runtime_config(options) or {}
  return tonumber(runtime_config.bridge_wait_ms or 5000) or 5000
end

runtime_ready = function(bufnr)
  if not is_ark_runtime_buffer(bufnr) then
    return false
  end

  local tmux_status = session_backend.status(options)
  local lsp_status = lsp.status(options, bufnr)
  local bridge_ready = type(tmux_status) == "table" and tmux_status.bridge_ready == true
  local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil

  return bridge_ready
    and type(lsp_status) == "table"
    and lsp_status.available == true
    and lsp_status.sessionBridgeConfigured == true
    and type(detached_status) == "table"
    and detached_status.lastSessionUpdateStatus == "ready"
end

local function live_lsp_client_attached(bufnr)
  if type(bufnr) ~= "number" or not options or type(options.lsp) ~= "table" then
    return false
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  for _, client in ipairs(vim.lsp.get_clients({ name = options.lsp.name, bufnr = bufnr })) do
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

  local status = console.status(bufnr)
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

local function register_help_rpc()
  _G[help_rpc_fn] = function(topic)
    if type(topic) ~= "string" or topic == "" then
      error("ArkHelp RPC requires a non-empty topic", 0)
    end

    vim.schedule(function()
      local help_bufnr = resolve_explicit_help_bufnr(0)
      local ok, err = pcall(function()
        return M.help_topic(topic, help_bufnr)
      end)
      if not ok then
        notify(tostring(err), vim.log.levels.WARN)
      end
    end)

    return "ok"
  end
end

local function register_view_rpc()
  _G[view_rpc_fn] = function(expr)
    if type(expr) ~= "string" or expr == "" then
      error("ArkView RPC requires a non-empty expression", 0)
    end

    vim.schedule(function()
      local view_bufnr = resolve_explicit_help_bufnr(0)
      local ok, err = pcall(function()
        if should_use_tmux_view_popup() then
          return M.view_popup(expr, view_bufnr)
        end
        return M.view(expr, view_bufnr)
      end)
      if not ok then
        notify(tostring(err), vim.log.levels.WARN)
      end
    end)

    return "ok"
  end
end

local function console_runtime_ready(bufnr)
  if not active_console_status(bufnr) then
    return false
  end

  local lsp_status = lsp.status(options, bufnr)
  local detached_status = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil

  return type(lsp_status) == "table"
    and lsp_status.available == true
    and lsp_status.sessionBridgeConfigured == true
    and type(detached_status) == "table"
    and detached_status.lastSessionUpdateStatus == "ready"
end

repl_ready = function()
  local status = session_backend.status(options)
  return type(status) == "table" and status.repl_ready == true
end

local function wait_for_repl_ready_for_send()
  local runtime_config = session_backend.runtime_config(options) or {}
  if console_frontend.normalize(runtime_config.console_frontend) == "nvim-console" then
    local function console_ready()
      return session_backend.console_ready(options) == true
    end

    if console_ready() then
      return true, nil
    end

    local timeout_ms = runtime_wait_timeout_ms()
    if vim.wait(timeout_ms, console_ready, 50, false) then
      return true, nil
    end

    return nil, "managed nvim-console RPC endpoint is not ready for send"
  end

  if repl_ready() then
    return true, nil
  end

  local timeout_ms = runtime_wait_timeout_ms()
  local ready = vim.wait(timeout_ms, repl_ready, 50, false)
  if ready then
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
  bufnr = resolve_bufnr(bufnr)
  label = label or "ark.nvim runtime"

  if not is_ark_runtime_buffer(bufnr) then
    return nil, label .. " requires an R-family buffer"
  end

  lsp.start(options, bufnr)

  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end

  local _, pane_err = start_or_recover_pane_after_runtime_ready({
    recover_bridge_failure = true,
  })
  if pane_err then
    return nil, pane_err
  end

  lsp.sync_sessions(options, bufnr)

  if not wait_for_help_runtime(bufnr) then
    return nil, label .. " bridge is not ready"
  end

  return true
end

local function with_managed_session_ready(bufnr, label, callback, runtime_opts)
  runtime_opts = runtime_opts or {}
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

    local pane_id, pane_err = start_or_recover_pane_after_runtime_ready({
      recover_bridge_failure = true,
    })
    if not pane_id then
      return nil, pane_err or "failed to start managed R pane", "runtime"
    end

    lsp.sync_sessions(options, bufnr)
    local result, err, err_source = wait_until(bufnr, label, done)
    if err_source == "queued" then
      vim.defer_fn(function()
        drain_all_ready_waiters(bufnr)
      end, 50)
    end
    return result, err, err_source
  end

  if runtime_opts.start_lsp ~= false then
    lsp.start(options, bufnr)
  end

  local bridge_complete = false
  local bridge_ok, bridge_err, bridge_kind = ensure_bridge_runtime({
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
            lsp.start(options, bufnr)
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
    lsp.start(options, bufnr)
    if type(request_bufnr) == "number" and request_bufnr ~= bufnr and vim.api.nvim_buf_is_valid(request_bufnr) then
      lsp.start(options, request_bufnr)
    end
  end

  lsp.sync_sessions(options, bufnr)

  local result, err, err_source = wait_until(bufnr, label, done)
  if err_source == "queued" then
    vim.defer_fn(function()
      drain_all_ready_waiters(bufnr)
    end, 50)
  end
  return result, err, err_source
end

local function with_runtime_ready(bufnr, label, callback, runtime_opts)
  return with_managed_session_ready(bufnr, label, callback, runtime_opts)
end

is_ark_buffer = function(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and options ~= nil
    and vim.b[bufnr].ark_console ~= true
    and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
end

is_ark_runtime_buffer = function(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and options ~= nil
    and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
end

local function is_ark_completion_buffer(bufnr)
  return bufnr ~= nil
    and vim.api.nvim_buf_is_valid(bufnr)
    and options ~= nil
    and (vim.b[bufnr].ark_console == true or vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype))
end

local function notify(message, level)
  notifications.emit(message, level or vim.log.levels.INFO)
end

local function merged_opts(base, opts)
  local merged = vim.tbl_deep_extend("force", config.defaults(), base or {}, opts or {})
  local frontend = type(merged.session) == "table" and merged.session.console_frontend or nil
  if type(frontend) == "string" and frontend ~= "" then
    merged.tmux = merged.tmux or {}
    merged.terminal = merged.terminal or {}
    merged.tmux.console_frontend = frontend
    merged.terminal.console_frontend = frontend
  end

  return merged
end

local function ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

ensure_bridge_runtime = function(bridge_opts)
  bridge_opts = bridge_opts or {}
  local state_bufnr = type(bridge_opts.bufnr) == "number" and bridge_opts.bufnr or vim.api.nvim_get_current_buf()
  local function transition(event, details)
    if type(state_bufnr) == "number" then
      startup:transition(state_bufnr, event, details)
    end
  end
  local runtime_config = session_backend.runtime_config(options)
  if type(runtime_config) ~= "table" then
    return true
  end

  local completed = nil
  local ok, err = bridge.ensure_current_runtime(runtime_config, {
    on_build_complete = function(result)
      completed = result
      if type(bridge_opts.on_build_complete) == "function" then
        bridge_opts.on_build_complete(result)
      end
    end,
    user_initiated = bridge_opts.user_initiated == true,
  })
  if ok then
    return true
  end

  local message = type(err) == "table" and err.message or err
  if type(err) == "table" and err.kind == "build_pending" then
    transition("bridge_installing")
  end
  if bridge_opts.wait_on_pending == true and type(err) == "table" and err.kind == "build_pending" then
    local timeout_ms = tonumber(bridge_opts.timeout_ms or 20000) or 20000
    local waited = vim.wait(timeout_ms, function()
      return type(completed) == "table"
    end, 50, false)
    local failure_message = (type(completed) == "table" and completed.error) or message
    if not waited or completed.ok ~= true then
      transition("degraded", { error = failure_message })
      if bridge_opts.notify ~= false and type(failure_message) == "string" and failure_message ~= "" then
        notify(failure_message, vim.log.levels.ERROR)
      end
      return nil, failure_message
    end

    local retry_ok, retry_err = ensure_bridge_runtime(vim.tbl_extend("force", bridge_opts, {
      wait_on_pending = false,
      on_build_complete = nil,
      notify = false,
    }))
    if not retry_ok and bridge_opts.notify ~= false and type(retry_err) == "string" and retry_err ~= "" then
      notify(retry_err, vim.log.levels.ERROR)
    end
    return retry_ok, retry_err
  end

  if bridge_opts.notify ~= false and type(message) == "string" and message ~= "" then
    notify(message, bridge_opts.pending_level or vim.log.levels.INFO)
  end

  if type(err) ~= "table" or err.kind ~= "build_pending" then
    transition("degraded", { error = message })
  end

  return nil, message, type(err) == "table" and err.kind or nil
end

local function sync_sessions_soon()
  pending_session_sync = pending_session_sync + 1
  local token = pending_session_sync

  vim.schedule(function()
    if token ~= pending_session_sync then
      return
    end
    if not options then
      return
    end

    lsp.sync_sessions(options, nil, { fast = true })
  end)
end

local function slime_target()
  local target = vim.b.slime_target or vim.g.slime_target
  if type(target) == "string" and target ~= "" then
    return target
  end

  local resolve = vim.fn["slime#config#resolve"]
  if type(resolve) == "function" then
    local ok, resolved = pcall(resolve, "target")
    if ok and type(resolved) == "string" and resolved ~= "" then
      return resolved
    end
  end

  return nil
end

local pending_slime_config_key = "__ark_pending"

local function is_pending_slime_config(config)
  return type(config) == "table" and config[pending_slime_config_key] == true
end

local function slime_config(fallback)
  local buffer_config = vim.b.slime_config
  local default_config = vim.g.slime_default_config

  if type(buffer_config) == "table" and not is_pending_slime_config(buffer_config) then
    return buffer_config
  end

  if type(default_config) == "table" and not is_pending_slime_config(default_config) then
    return default_config
  end

  if type(buffer_config) == "table" then
    return buffer_config
  end

  if type(default_config) == "table" then
    return default_config
  end

  return fallback
end

local function seed_pending_slime_config()
  if session_backend.backend_name(options) ~= "tmux" then
    return
  end
  if type(vim.g.slime_default_config) == "table" then
    return
  end

  vim.g.slime_target = "tmux"
  vim.g.slime_default_config = {
    socket_name = "",
    target_pane = "",
    [pending_slime_config_key] = true,
  }
end

local function default_slime_send(config_arg, text)
  local target = slime_target()
  if type(target) ~= "string" or target == "" then
    return nil, "vim-slime target is not configured"
  end

  local send = vim.fn["slime#targets#" .. target .. "#send"]
  local ok, result = pcall(send, slime_config(config_arg), text)
  if not ok then
    return nil, tostring(result)
  end

  return result == nil and true or result, nil
end

local function using_nvim_console_frontend()
  local runtime_config = session_backend.runtime_config(options)
  return console_frontend.normalize(runtime_config and runtime_config.console_frontend) == "nvim-console"
end

local function status_has_bridge_runtime_failure(status)
  if type(status) ~= "table" or status.pane_exists ~= true or status.bridge_ready == true then
    return false
  end

  local startup = type(status.startup_status) == "table" and status.startup_status or nil
  return type(startup) == "table" and startup.status == "error" and startup.error_code == "E_BRIDGE_MISSING"
end

start_or_recover_pane_after_runtime_ready = function(opts)
  opts = opts or {}
  if opts.recover_bridge_failure ~= true then
    return session_backend.start(options)
  end

  local status = session_backend.status(options)
  if status_has_bridge_runtime_failure(status) then
    return session_backend.restart(options)
  end

  return session_backend.start(options)
end

local function install_slime_override()
  _G.__ark_slime_override_send = function(config_arg, text)
    local ok, err = M._slime_override_send(config_arg, text)
    if ok then
      return nil
    end
    return err or "failed to send text through vim-slime"
  end

  if vim.g.ark_slime_override_send_installed == 1 then
    seed_pending_slime_config()
    return
  end

  if vim.fn.exists("*SlimeOverrideSend") == 1 then
    if vim.g.ark_slime_override_send_conflict_notified ~= 1 then
      vim.g.ark_slime_override_send_conflict_notified = 1
      notify("vim-slime SlimeOverrideSend already exists; Ark closed-pane send preflight is disabled", vim.log.levels.WARN)
    end
    return
  end

  vim.g.ark_slime_override_send_installed = 1
  seed_pending_slime_config()
  vim.cmd([[
function! SlimeOverrideSend(config, text) abort
  let l:ark_err = v:lua.__ark_slime_override_send(a:config, a:text)
  if type(l:ark_err) == v:t_string && l:ark_err !=# ''
    throw 'ark.nvim: ' . l:ark_err
  endif
endfunction
]])
end

local function start_managed_buffer(bufnr)
  if not options or type(bufnr) ~= "number" then
    return
  end
  if vim.b[bufnr].ark_console == true then
    return
  end

  local token = startup:begin(bufnr)

  local function can_start_buffer()
    return startup:is_current(bufnr, token)
      and vim.api.nvim_buf_is_valid(bufnr)
      and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
  end

  local function start_sync_lsp_later()
    vim.schedule(function()
      if not can_start_buffer() then
        return
      end

      lsp.start(options, bufnr)
    end)
  end

  local function prewarm_lsp()
    if not options.auto_start_lsp then
      return
    end

    if options.auto_start_pane and not options.async_startup and type(lsp.prewarm) == "function" then
      lsp.prewarm(options, bufnr)
      return
    end

    lsp.start_async(options, bufnr)
  end

  local function start_pane_and_sync(start_opts)
    if not can_start_buffer() then
      return
    end

    local _, pane_err = start_or_recover_pane_after_runtime_ready({
      recover_bridge_failure = type(start_opts) == "table" and start_opts.recover_bridge_failure == true,
    })
    if pane_err then
      notify(pane_err, vim.log.levels.WARN)
      return
    end

    if options.auto_start_lsp and (options.auto_start_pane or not options.async_startup) then
      start_sync_lsp_later()
    end
  end

  local function start_buffer()
    if not can_start_buffer() then
      return
    end

    prewarm_lsp()

    if options.auto_start_pane then
      local bridge_ok = ensure_bridge_runtime({
        bufnr = bufnr,
        on_build_complete = function(result)
          if type(result) ~= "table" or result.ok ~= true then
            return
          end

          vim.schedule(function()
            start_pane_and_sync({
              recover_bridge_failure = true,
            })
          end)
        end,
      })
      if bridge_ok then
        start_pane_and_sync()
      end
      return
    end

    if options.auto_start_lsp and not options.async_startup then
      start_sync_lsp_later()
    end
  end

  if options.async_startup then
    vim.schedule(start_buffer)
    return
  end

  start_buffer()
end

function M.setup(opts)
  config.assert_valid(opts)
  options = merged_opts(options, opts)
  target_actions = target_actions_module.new({
    add_candidate_bufnr = add_candidate_bufnr,
    current_nvim_server = current_nvim_server,
    ensure_runtime_ready = ensure_runtime_ready,
    ensure_setup = ensure_setup,
    expression = expression,
    is_ark_runtime_buffer = is_ark_runtime_buffer,
    lsp = lsp,
    normalize_view_display = normalize_view_display,
    notify = notify,
    options = options,
    refresh = function(...)
      return M.refresh(...)
    end,
    resolve_bufnr = resolve_bufnr,
    resolve_view_source_bufnr = resolve_view_source_bufnr,
    r_string_literal = r_string_literal,
    send = function(...)
      return M.send(...)
    end,
    session_backend = session_backend,
    should_use_tmux_view_popup = should_use_tmux_view_popup,
    target_tools = target_tools,
    target_view = target_view,
    view = view,
    view_popup_backend = view_popup_backend,
    with_runtime_ready = with_runtime_ready,
  })
  register_help_rpc()
  register_view_rpc()
  if type(lsp.set_startup_ready_callback) == "function" then
    lsp.set_startup_ready_callback(function(bufnr, payload)
      startup:mark_live_hydrated(bufnr, type(payload) == "table" and payload.source or "LspBootstrap")
      drain_all_ready_waiters(bufnr)
      if type(blink.maybe_show_after_startup) == "function" then
        vim.defer_fn(function()
          blink.maybe_show_after_startup(bufnr)
        end, 20)
      end
    end)
  end
  if type(blink.ensure_integration) == "function" then
    blink.ensure_integration()
  end

  local group = vim.api.nvim_create_augroup("ArkNvim", { clear = true })
  keymaps.setup(options)
  if options.configure_slime == true then
    install_slime_override()
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = options.filetypes,
    callback = function(args)
      start_managed_buffer(args.buf)
    end,
    desc = "Start ark.nvim pane and LSP for R-family buffers",
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    pattern = "*",
    callback = function(args)
      if not is_ark_completion_buffer(args.buf) then
        return
      end
      vim.schedule(function()
        if type(blink.ensure_integration) == "function" then
          blink.ensure_integration()
        end
      end)
    end,
    desc = "Apply Ark Blink runtime patches after Blink initialization",
  })

  vim.api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    pattern = "*",
    callback = function(args)
      if not is_ark_completion_buffer(args.buf) then
        return
      end
      if not startup:unlocked(args.buf) then
        return
      end
      blink.handle_insert_char_pre(args.buf)
    end,
    desc = "Track opening-pair insertions for Ark completion recovery",
  })

  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      startup:mark_safe(vim.api.nvim_get_current_buf(), "SafeState")
    end,
    desc = "Record the first post-startup SafeState for the current Ark buffer",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      session_backend.stop(options)
    end,
    desc = "Stop the managed ark.nvim session on exit",
  })

  did_setup = true

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr)
      and vim.b[bufnr].ark_console ~= true
      and vim.tbl_contains(options.filetypes, vim.bo[bufnr].filetype)
    then
      start_managed_buffer(bufnr)
    end
  end

  vim.api.nvim_create_user_command("ArkBuildLsp", function()
    local ok, err = dev.build_detached_lsp({
      binary_path = options.lsp and options.lsp.cmd and options.lsp.cmd[1] or nil,
      show_output = true,
    })
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end, { desc = "Rebuild the detached ark-lsp binary used by ark.nvim" })

  vim.api.nvim_create_user_command("ArkBuildBridge", function()
    local runtime_config, config_err = session_backend.runtime_config(options)
    if type(runtime_config) ~= "table" then
      notify(config_err, vim.log.levels.ERROR)
      return
    end

    local ok, err = bridge.build_session_runtime(runtime_config, {})
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end, { desc = "Rebuild the pane-side arkbridge runtime used by ark.nvim" })

  return options
end

function M.console()
  ensure_setup()
  return console.start(options)
end

function M.console_interrupt(bufnr)
  ensure_setup()
  return console.interrupt(bufnr or 0)
end

function M.console_eof(bufnr)
  ensure_setup()
  return console.eof(bufnr or 0)
end

function M.console_stop(bufnr)
  ensure_setup()
  return console.stop(bufnr or 0)
end

function M.options()
  ensure_setup()
  return options
end

function M.configured_options()
  return did_setup and options or nil
end

function M.pane_command()
  ensure_setup()
  return session_backend.pane_command(options)
end

local function prewarm_current_buffer_lsp()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_ark_buffer(bufnr) then
    return nil
  end

  -- Command-driven integrations often call `start_pane()` and `start_lsp()`
  -- back-to-back. Prewarm the detached client here so those phases do not
  -- serialize on the pane path.
  if type(lsp.prewarm) == "function" then
    return lsp.prewarm(options, bufnr)
  end

  return lsp.start_async(options, bufnr)
end

function M.start_pane()
  ensure_setup()
  local bufnr = vim.api.nvim_get_current_buf()
  prewarm_current_buffer_lsp()
  local bridge_ok, bridge_err = ensure_bridge_runtime({
    bufnr = bufnr,
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end
  local pane_id, err = start_or_recover_pane_after_runtime_ready({
    recover_bridge_failure = true,
  })
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  lsp.sync_sessions(options)
  return pane_id
end

function M.new_tab()
  ensure_setup()
  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end
  local pane_id, err = session_backend.tab_new(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.next_tab()
  ensure_setup()
  local pane_id, err = session_backend.tab_next(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.prev_tab()
  ensure_setup()
  local pane_id, err = session_backend.tab_prev(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.go_tab(index)
  ensure_setup()
  local pane_id, err = session_backend.tab_go(index, options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.close_tab()
  ensure_setup()
  local pane_id, err = session_backend.tab_close(options)
  if err then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.list_tabs()
  ensure_setup()
  return session_backend.tab_list(options)
end

function M.tab_state()
  ensure_setup()
  return session_backend.tab_state(options)
end

function M.tab_badge()
  ensure_setup()
  return session_backend.tab_badge(options)
end

function M.restart_pane()
  ensure_setup()
  local bufnr = vim.api.nvim_get_current_buf()
  startup:transition(bufnr, "restarting")
  local bridge_ok, bridge_err = ensure_bridge_runtime({
    bufnr = bufnr,
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end
  local pane_id, err = session_backend.restart(options)
  if not pane_id then
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  sync_sessions_soon()
  return pane_id
end

function M.stop_pane()
  ensure_setup()
  local bufnr = vim.api.nvim_get_current_buf()
  startup:transition(bufnr, "stopping")
  session_backend.stop(options)
  startup:transition(bufnr, "stopped")
  sync_sessions_soon()
end

function M.start_lsp(bufnr)
  ensure_setup()
  return lsp.start(options, resolve_bufnr(bufnr))
end

function M.snippets(bufnr)
  ensure_setup()
  return snippets.open({
    bufnr = resolve_bufnr(bufnr),
    filetypes = options.filetypes,
    notify = notify,
  })
end

function M._slime_before_send()
  ensure_setup()

  if options.configure_slime ~= true then
    return true, nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if not is_ark_buffer(bufnr) then
    return true, nil
  end

  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    return nil, bridge_err
  end

  local pane_id, pane_err = start_or_recover_pane_after_runtime_ready({
    recover_bridge_failure = true,
  })
  if not pane_id then
    return nil, pane_err
  end

  local repl_ok, repl_err = wait_for_repl_ready_for_send()
  if not repl_ok then
    return nil, repl_err
  end

  sync_sessions_soon()
  return true, nil
end

function M._slime_override_send(config_arg, text, delegate)
  local ready, ready_err = M._slime_before_send()
  if not ready then
    return nil, ready_err
  end

  if using_nvim_console_frontend() and type(delegate) ~= "function" then
    local backend_ok, backend_err = session_backend.send_text(options, text)
    if backend_ok then
      return true, nil
    end
    return nil, backend_err or "ark.nvim nvim-console send failed"
  end

  local send = type(delegate) == "function" and delegate or default_slime_send
  local ok, result, send_err = pcall(send, slime_config(config_arg), text)
  if not ok then
    return nil, tostring(result)
  end

  if result == nil or result == false then
    return nil, send_err or "vim-slime send failed"
  end

  return true, nil
end

function M.send(text)
  ensure_setup()

  if type(text) ~= "string" or text == "" then
    local err = "ark.nvim send() requires non-empty text"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local bridge_ok, bridge_err = ensure_bridge_runtime({
    user_initiated = true,
    wait_on_pending = true,
  })
  if not bridge_ok then
    notify(bridge_err, vim.log.levels.ERROR)
    return nil, bridge_err
  end

  local pane_id, pane_err = start_or_recover_pane_after_runtime_ready({
    recover_bridge_failure = true,
  })
  if not pane_id then
    notify(pane_err, vim.log.levels.ERROR)
    return nil, pane_err
  end

  local repl_ok, repl_err = wait_for_repl_ready_for_send()
  if not repl_ok then
    notify(repl_err, vim.log.levels.ERROR)
    return nil, repl_err
  end

  sync_sessions_soon()

  local ok, send_err = session_backend.send_text(options, text)
  if not ok then
    notify(send_err, vim.log.levels.ERROR)
    return nil, send_err
  end

  return true, nil
end

local function show_help_page(bufnr, topic)
  bufnr = resolve_bufnr(bufnr)

  local explicit_topic = type(topic) == "string" and topic ~= ""
  local use_console_runtime = explicit_topic and active_console_status(bufnr) ~= nil
  if not is_ark_buffer(bufnr) and not use_console_runtime then
    local err = "ark.nvim help requires an R-family buffer"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  lsp.start(options, bufnr)

  if type(topic) ~= "string" or topic == "" then
    local topic_err
    topic, topic_err = lsp.help_topic(options, bufnr)
    if not topic then
      notify(topic_err or "no help topic found", vim.log.levels.WARN)
      return nil, topic_err
    end
  end

  local function open_help(runtime_err)
    if runtime_err then
      notify(runtime_err, vim.log.levels.WARN)
      return nil, runtime_err
    end

    local page, page_err = lsp.help_text(options, bufnr, topic)
    if not page then
      notify(page_err or "no help text found", vim.log.levels.WARN)
      return nil, page_err
    end

    if should_use_tmux_help_popup() then
      local popup_ok, popup_err = open_help_popup(page, topic, bufnr)
      if popup_ok then
        return topic, nil
      end
      notify(popup_err or "tmux ArkHelp popup failed; opening Neovim help float", vim.log.levels.WARN)
    end

    open_readonly_float(page.text, {
      topic = topic,
      references = page.references,
      source_bufnr = bufnr,
      on_request_page = function(target)
        return lsp.help_text(options, bufnr, target)
      end,
    })

    return topic, nil
  end

  if not use_console_runtime then
    return open_help(nil)
  end

  local opened_topic, runtime_err, err_source = with_console_session_ready(bufnr, "ark.nvim help", open_help, {
    start_lsp = false,
  })
  if not opened_topic and runtime_err and err_source ~= "callback" then
    notify(runtime_err, vim.log.levels.WARN)
    return nil, runtime_err
  end
  if not opened_topic and runtime_err then
    return nil, runtime_err
  end

  return topic, nil
end

function M.help_pane(bufnr)
  ensure_setup()
  bufnr = resolve_bufnr(bufnr)

  if not is_ark_buffer(bufnr) then
    local err = "ark.nvim help requires an R-family buffer"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  lsp.start(options, bufnr)

  local topic, topic_err = lsp.help_topic(options, bufnr)
  if not topic then
    notify(topic_err or "no help topic found", vim.log.levels.WARN)
    return nil, topic_err
  end

  local function send_help(runtime_err)
    if runtime_err then
      notify(runtime_err, vim.log.levels.WARN)
      return nil, runtime_err
    end

    local ok, send_err = session_backend.send_text(options, help_expression(topic))
    if not ok then
      notify(send_err, vim.log.levels.ERROR)
      return nil, send_err
    end

    return topic, nil
  end

  local sent, wait_err, err_source = with_managed_session_ready(bufnr, "ark.nvim help pane", send_help, {
    start_lsp = false,
    wait_until_ready = wait_until_repl_ready,
  })
  if not sent and wait_err and err_source ~= "callback" then
    notify(wait_err, vim.log.levels.WARN)
    return nil, wait_err
  end
  if not sent and wait_err then
    return nil, wait_err
  end

  return topic, nil
end

function M.help(bufnr)
  ensure_setup()
  return show_help_page(bufnr, nil)
end

function M.help_topic(topic, bufnr)
  ensure_setup()
  if type(topic) ~= "string" or topic == "" then
    local err = "ark.nvim help topic requires a non-empty topic"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end
  return show_help_page(bufnr, topic)
end

function M.view_popup(expr, bufnr)
  ensure_setup()
  bufnr = resolve_bufnr(bufnr)

  if type(expr) ~= "string" or expr == "" then
    expr = expression.current()
  end
  if type(expr) ~= "string" or expr == "" then
    local err = "no ArkView expression found"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local source_bufnr = resolve_view_source_bufnr(bufnr)
  if type(source_bufnr) ~= "number" then
    local err = "ark.nvim data explorer requires an R-family buffer"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local target_name = tar_read_target_name(expr)
  if target_name and not active_console_status(bufnr) then
    return M.targets_view(target_name, source_bufnr)
  end

  local function open_current_ui()
    local opened, open_err = view.open({
      expr = expr,
      source_bufnr = source_bufnr,
      options = options,
      lsp = lsp,
      notify = notify,
    })
    if not opened then
      notify(open_err or "failed to open ArkView", vim.log.levels.WARN)
      return nil, open_err
    end

    return opened
  end

  local function open_popup(runtime_err)
    if runtime_err then
      notify(runtime_err, vim.log.levels.WARN)
      return nil, runtime_err
    end

    local console_status = active_console_status(bufnr)
    local server = console_status and console_status.rpc_socket or nil
    local opened, popup_err = open_view_tmux_popup(expr, source_bufnr, server)
    if opened then
      return opened
    end

    local view_opts = type(options) == "table" and type(options.view) == "table" and options.view or {}
    if normalize_view_display(view_opts.display) == "tmux_popup" then
      local err = popup_err or "failed to open tmux ArkView popup"
      notify(err, vim.log.levels.WARN)
      return nil, err
    end

    return open_current_ui()
  end

  local runtime_bufnr = source_bufnr
  local runtime_ready_fn = with_runtime_ready
  local runtime_opts = nil
  if active_console_status(bufnr) then
    runtime_bufnr = bufnr
    runtime_ready_fn = with_console_session_ready
    runtime_opts = {
      request_bufnr = source_bufnr,
    }
  end

  local opened, runtime_err, err_source =
    runtime_ready_fn(runtime_bufnr, "ark.nvim data explorer", open_popup, runtime_opts)
  if not opened and runtime_err and err_source ~= "callback" then
    notify(runtime_err, vim.log.levels.WARN)
    return nil, runtime_err
  end
  if not opened and runtime_err then
    return nil, runtime_err
  end

  return opened
end

function M.view(expr, bufnr, view_opts)
  ensure_setup()
  bufnr = resolve_bufnr(bufnr)
  view_opts = type(view_opts) == "table" and view_opts or {}
  local function close_view_popup()
    if type(view_opts.on_close) == "function" then
      pcall(view_opts.on_close)
    end
  end

  if type(expr) ~= "string" or expr == "" then
    expr = expression.current()
  end
  if type(expr) ~= "string" or expr == "" then
    local err = "no ArkView expression found"
    close_view_popup()
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local source_bufnr = resolve_view_source_bufnr(bufnr)
  if type(source_bufnr) ~= "number" then
    local err = "ark.nvim data explorer requires an R-family buffer"
    close_view_popup()
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local target_name = tar_read_target_name(expr)
  if target_name and not active_console_status(bufnr) then
    return M.targets_view(target_name, source_bufnr)
  end

  local function open_view(runtime_err)
    if runtime_err then
      close_view_popup()
      notify(runtime_err, vim.log.levels.WARN)
      return nil, runtime_err
    end

    local opened, open_err = view.open({
      expr = expr,
      source_bufnr = source_bufnr,
      options = options,
      lsp = lsp,
      notify = notify,
      on_close = view_opts.on_close,
    })
    if not opened then
      close_view_popup()
      notify(open_err or "failed to open ArkView", vim.log.levels.WARN)
      return nil, open_err
    end

    return opened
  end

  local runtime_bufnr = source_bufnr
  local runtime_ready_fn = with_runtime_ready
  local runtime_opts = nil
  if active_console_status(bufnr) then
    runtime_bufnr = bufnr
    runtime_ready_fn = with_console_session_ready
    runtime_opts = {
      request_bufnr = source_bufnr,
    }
  end

  local opened, runtime_err, err_source =
    runtime_ready_fn(runtime_bufnr, "ark.nvim data explorer", open_view, runtime_opts)
  if not opened and runtime_err and err_source ~= "callback" then
    close_view_popup()
    notify(runtime_err, vim.log.levels.WARN)
    return nil, runtime_err
  end
  if not opened and runtime_err then
    close_view_popup()
    return nil, runtime_err
  end

  return opened
end

function M.view_under_cursor(bufnr)
  ensure_setup()
  return M.view(expression.current(), bufnr)
end

function M.view_refresh()
  ensure_setup()
  return view.refresh()
end

function M.view_close()
  ensure_setup()
  return view.close()
end

function M.view_column_width(width_spec, column)
  ensure_setup()
  local result, err = view.set_column_width(width_spec, column)
  if err then
    notify(err, vim.log.levels.WARN)
  end
  return result, err
end

function M.view_column_wrap(mode, column)
  ensure_setup()
  local result, err = view.set_column_wrap(mode, column)
  if err then
    notify(err, vim.log.levels.WARN)
  end
  return result, err
end

local function target_actions_controller()
  ensure_setup()
  return target_actions
end

tar_read_target_name = function(expr)
  return target_actions_controller().tar_read_target_name(expr)
end

function M.targets_project(bufnr)
  return target_actions_controller().targets_project(bufnr)
end

function M.targets_script(bufnr)
  return target_actions_controller().targets_script(bufnr)
end

function M.missing_packages(bufnr)
  return target_actions_controller().missing_packages(bufnr)
end

function M.install_missing_packages(bufnr, install_opts)
  return target_actions_controller().install_missing_packages(bufnr, install_opts)
end

function M.targets_project_info(bufnr)
  return target_actions_controller().targets_project_info(bufnr)
end

function M.targets_manifest(bufnr)
  return target_actions_controller().targets_manifest(bufnr)
end

function M.targets_set_active(name, bufnr)
  return target_actions_controller().targets_set_active(name, bufnr)
end

function M.targets_active(bufnr)
  return target_actions_controller().targets_active(bufnr)
end

function M.targets_pick(bufnr, callback)
  return target_actions_controller().targets_pick(bufnr, callback)
end

function M.targets_view(name, bufnr)
  return target_actions_controller().targets_view(name, bufnr)
end

function M.targets_view_pick(bufnr)
  return target_actions_controller().targets_view_pick(bufnr)
end

function M.targets_network(bufnr)
  return target_actions_controller().targets_network(bufnr)
end

function M.targets_graph(bufnr)
  return target_actions_controller().targets_graph(bufnr)
end

function M.targets_meta(names, bufnr)
  return target_actions_controller().targets_meta(names, bufnr)
end

function M.targets_status(names, bufnr)
  return target_actions_controller().targets_status(names, bufnr)
end

function M.targets_log(names, bufnr)
  return target_actions_controller().targets_log(names, bufnr)
end

function M.targets_object_meta(name, bufnr)
  return target_actions_controller().targets_object_meta(name, bufnr)
end

function M.targets_load(names, bufnr)
  return target_actions_controller().targets_load(names, bufnr)
end

function M.targets_action(action, names, bufnr)
  return target_actions_controller().targets_action(action, names, bufnr)
end

function M.targets_action_user(action, names, bufnr)
  return target_actions_controller().targets_action_user(action, names, bufnr)
end

function M.targets_action_pick(action, bufnr)
  return target_actions_controller().targets_action_pick(action, bufnr)
end

function M.targets_action_active(action, bufnr)
  return target_actions_controller().targets_action_active(action, bufnr)
end


function M.refresh(bufnr)
  ensure_setup()

  if options.auto_start_pane then
    local bridge_ok = ensure_bridge_runtime({})
    if bridge_ok then
      local _, pane_err = start_or_recover_pane_after_runtime_ready({
        recover_bridge_failure = true,
      })
      if pane_err then
        notify(pane_err, vim.log.levels.WARN)
      end
    end
  end

  return lsp.refresh(options, resolve_bufnr(bufnr))
end

function M.lsp_config(bufnr)
  ensure_setup()
  return lsp.config(options, resolve_bufnr(bufnr))
end

function M.build_lsp()
  ensure_setup()
  return dev.build_detached_lsp({
    binary_path = options.lsp and options.lsp.cmd and options.lsp.cmd[1] or nil,
  })
end

function M.build_bridge()
  ensure_setup()
  local runtime_config, config_err = session_backend.runtime_config(options)
  if type(runtime_config) ~= "table" then
    return nil, config_err
  end

  return bridge.build_session_runtime(runtime_config, {})
end

function M.status(opts)
  ensure_setup()
  opts = opts or {}
  local status = session_backend.status(options)
  if opts.include_secrets ~= true and type(status.startup_status) == "table" then
    status.startup_status.auth_token = status.startup_status.auth_token and "<redacted>" or nil
  end
  status.startup = startup:status(vim.api.nvim_get_current_buf())
  status.lsp_cmd = options.lsp.cmd
  status.release = release.status()
  status.config_valid = true
  local runtime_config = session_backend.runtime_config(options) or {}
  status.backend = session_backend.backend_name(options)
  status.console_frontend = runtime_config.console_frontend
  status.launcher = runtime_config.launcher
  if opts.include_lsp == true then
    status.lsp_status = lsp.status(options)
    local detached_status = type(status.lsp_status) == "table" and status.lsp_status.detachedSessionStatus or nil
    if type(detached_status) == "table"
      and type(detached_status.lastBootstrapSuccessMs) == "number"
      and status.startup.main_buffer_unlocked == true
      and status.startup.post_lsp_bootstrap_unlock_ms == nil
      and type(status.startup.main_buffer_unlock_at_ms) == "number"
    then
      status.startup.post_lsp_bootstrap_unlock_ms = math.max(
        0,
        status.startup.main_buffer_unlock_at_ms - detached_status.lastBootstrapSuccessMs
      )
    end
  end
  status.product_state = product_state.derive(status, options, bridge.status())
  status.product_state_detail = product_state.describe(status.product_state)
  return status
end

function M.support_status()
  if not did_setup then
    return {
      configured = false,
      product_state = "static_only",
      product_state_detail = product_state.describe("static_only"),
      release = release.status(),
    }
  end
  return M.status({ include_lsp = true })
end

return M
