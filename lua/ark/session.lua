local M = {}

local backend_specs = {
  terminal = {
    module = "ark.terminal",
    config_key = "terminal",
    tab_operations = false,
  },
  tmux = {
    module = "ark.tmux",
    config_key = "tmux",
    tab_operations = true,
  },
}

local function configured_backend(opts)
  local session = opts and opts.session or nil
  local backend = type(session) == "table" and session.backend or nil
  if type(backend) == "string" and backend ~= "" then
    return backend
  end

  return "tmux"
end

local function resolve_backend(opts)
  local backend_name = configured_backend(opts)
  local spec = backend_specs[backend_name]
  if not spec then
    return nil, "unsupported ark.nvim session backend: " .. tostring(backend_name)
  end

  return {
    name = backend_name,
    spec = spec,
    module = require(spec.module),
    config = opts and opts[spec.config_key] or nil,
  }, nil
end

local function call_with_opts(opts, method, ...)
  local backend, err = resolve_backend(opts)
  if not backend then
    return nil, err
  end

  local fn = backend.module[method]
  if type(fn) ~= "function" then
    return nil, string.format("ark.nvim session backend '%s' does not implement %s()", backend.name, method)
  end

  return fn(...)
end

local function call_with_config(opts, method, ...)
  local backend, err = resolve_backend(opts)
  if not backend then
    return nil, err
  end

  local fn = backend.module[method]
  if type(fn) ~= "function" then
    return nil, string.format("ark.nvim session backend '%s' does not implement %s()", backend.name, method)
  end

  return fn(backend.config, ...)
end

local function call_tab_operation(opts, method, ...)
  local backend, err = resolve_backend(opts)
  if not backend then
    return nil, err
  end

  if backend.spec.tab_operations ~= true then
    return nil, string.format("ark.nvim session backend '%s' does not support managed tab operations", backend.name)
  end

  local fn = backend.module[method]
  if type(fn) ~= "function" then
    return nil, string.format("ark.nvim session backend '%s' does not implement %s()", backend.name, method)
  end

  return fn(...)
end

function M.backend_name(opts)
  return configured_backend(opts)
end

function M.runtime_config(opts)
  local backend, err = resolve_backend(opts)
  if not backend then
    return nil, err
  end

  return backend.config, nil
end

function M.start(opts)
  return call_with_opts(opts, "start", opts)
end

function M.restart(opts)
  return call_with_opts(opts, "restart", opts)
end

function M.stop(opts)
  return call_with_opts(opts, "stop")
end

function M.session(opts)
  return call_with_config(opts, "session")
end

function M.status(opts)
  return call_with_config(opts, "status")
end

function M.startup_snapshot(opts, snapshot_opts)
  return call_with_config(opts, "startup_snapshot", snapshot_opts)
end

function M.startup_status(opts)
  return call_with_config(opts, "startup_status")
end

function M.startup_status_authoritative(opts)
  return call_with_config(opts, "startup_status_authoritative")
end

function M.startup_status_path(opts)
  return call_with_config(opts, "startup_status_path")
end

function M.bridge_env(opts, snapshot)
  return call_with_config(opts, "bridge_env", snapshot)
end

function M.pane_command(opts)
  return call_with_config(opts, "pane_command")
end

function M.send_text(opts, text)
  return call_with_opts(opts, "send_text", text)
end

function M.tab_new(opts)
  return call_tab_operation(opts, "tab_new", opts)
end

function M.tab_next(opts)
  return call_tab_operation(opts, "tab_next", opts)
end

function M.tab_prev(opts)
  return call_tab_operation(opts, "tab_prev", opts)
end

function M.tab_go(index, opts)
  return call_tab_operation(opts, "tab_go", index, opts)
end

function M.tab_close(opts)
  return call_tab_operation(opts, "tab_close", opts)
end

function M.tab_list(opts)
  return call_tab_operation(opts, "tab_list")
end

function M.tab_state(opts)
  return call_tab_operation(opts, "tab_state")
end

function M.tab_badge(opts)
  return call_tab_operation(opts, "tab_badge")
end

function M.session_id(opts, session)
  local backend, err = resolve_backend(opts)
  if not backend then
    return nil, err
  end

  local fn = backend.module.session_id
  if type(fn) ~= "function" then
    return nil
  end

  return fn(session), nil
end

return M
