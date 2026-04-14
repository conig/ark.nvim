local uv = vim.uv or vim.loop

local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local ROOT = repo_root()
local INSTALL_SCRIPT = ROOT .. "/scripts/ark-install-bridge.R"
local SOURCE_SCAN_CACHE_TTL_MS = 1000
local checked = {}
local source_scan_cache = {
  checked_ms = 0,
  newest_mtime = nil,
  newest_path = nil,
}
local install_state = {
  listeners = {},
  running = false,
  background = false,
  user_initiated = false,
  output = {},
  notify_id = nil,
  started_at = nil,
}

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local function monotonic_ms()
  local clock = ((uv and uv.hrtime) and uv.hrtime) or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function stat(path)
  return uv and uv.fs_stat and uv.fs_stat(path) or nil
end

local function stat_mtime(path)
  local info = stat(path)
  return info and info.mtime and info.mtime.sec or nil
end

local function dir_exists(path)
  local info = stat(path)
  return type(info) == "table" and info.type == "directory"
end

local function file_exists(path)
  local info = stat(path)
  return type(info) == "table" and info.type == "file"
end

local function notify(message, level, opts)
  local id = vim.notify(message, level or vim.log.levels.INFO, vim.tbl_extend("force", {
    title = "ark.nvim",
  }, opts or {}))
  if id ~= nil then
    install_state.notify_id = id
  end
end

local function append_output(data)
  if type(data) ~= "table" then
    return
  end

  for _, line in ipairs(data) do
    if type(line) == "string" and line ~= "" then
      install_state.output[#install_state.output + 1] = line
    end
  end
end

local function runtime_lib_path(config)
  return normalize_path(config and config.session_lib_path or nil)
end

local function bridge_source_paths()
  local paths = {}

  if vim.fn.executable("rg") == 1 then
    paths = vim.fn.systemlist({
      "rg",
      "--files",
      ROOT .. "/packages/arkbridge",
    })
    if vim.v.shell_error ~= 0 then
      paths = {}
    end
  end

  if #paths == 0 then
    paths = vim.fn.glob(ROOT .. "/packages/arkbridge/**/*", false, true)
  end

  local filtered = {}
  local seen = {}
  for _, path in ipairs(paths) do
    local normalized = normalize_path(path)
    if normalized and not seen[normalized] and file_exists(normalized) then
      filtered[#filtered + 1] = normalized
      seen[normalized] = true
    end
  end

  for _, extra in ipairs({
    ROOT .. "/packages/arkbridge/DESCRIPTION",
    ROOT .. "/packages/arkbridge/NAMESPACE",
  }) do
    local normalized = normalize_path(extra)
    if normalized and not seen[normalized] and file_exists(normalized) then
      filtered[#filtered + 1] = normalized
      seen[normalized] = true
    end
  end

  return filtered
end

local function newest_source_state()
  local now = monotonic_ms()
  if now - (tonumber(source_scan_cache.checked_ms) or 0) < SOURCE_SCAN_CACHE_TTL_MS then
    return source_scan_cache.newest_mtime, source_scan_cache.newest_path
  end

  local newest_mtime = 0
  local newest_path = nil

  for _, path in ipairs(bridge_source_paths()) do
    local mtime = stat_mtime(path)
    if type(mtime) == "number" and mtime > newest_mtime then
      newest_mtime = mtime
      newest_path = path
    end
  end

  source_scan_cache.checked_ms = now
  source_scan_cache.newest_mtime = newest_mtime
  source_scan_cache.newest_path = newest_path
  return newest_mtime, newest_path
end

local function stamp_path(lib_path)
  local normalized = normalize_path(lib_path)
  if not normalized then
    return nil
  end

  return normalized .. "/.arkbridge-install.json"
end

local function installed_package_dir(lib_path)
  local normalized = normalize_path(lib_path)
  if not normalized then
    return nil
  end

  return normalized .. "/arkbridge"
end

local function read_stamp(lib_path)
  local path = stamp_path(lib_path)
  if not path or vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local ok, payload = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(payload) ~= "table" then
    return nil
  end

  payload.source_mtime = tonumber(payload.source_mtime) or nil
  return payload
end

local function current_install_source_mtime(lib_path)
  local stamp = read_stamp(lib_path)
  if type(stamp) == "table" and type(stamp.source_mtime) == "number" then
    return stamp.source_mtime
  end

  return nil
end

local function install_output_text()
  local output = vim.trim(table.concat(install_state.output or {}, "\n"))
  if output ~= "" then
    return output
  end

  return "arkbridge install failed"
end

local function finish_install(result)
  local listeners = install_state.listeners
  local background = install_state.background == true
  local user_initiated = install_state.user_initiated == true
  local elapsed_ms = install_state.started_at and (monotonic_ms() - install_state.started_at) or nil

  install_state.listeners = {}
  install_state.running = false
  install_state.background = false
  install_state.user_initiated = false
  install_state.started_at = nil

  if result.ok then
    checked = {}
    source_scan_cache.checked_ms = 0
    if not background or user_initiated then
      local suffix = elapsed_ms and string.format(" in %d ms", elapsed_ms) or ""
      notify("pane-side arkbridge runtime installed" .. suffix, vim.log.levels.INFO, {
        replace = install_state.notify_id,
      })
    end
  else
    local message = install_output_text()
    if background and not user_initiated then
      notify("background arkbridge install failed; continuing with current runtime", vim.log.levels.WARN, {
        replace = install_state.notify_id,
      })
    else
      notify("arkbridge install failed: " .. message, vim.log.levels.ERROR, {
        replace = install_state.notify_id,
      })
    end
    result.error = message
  end

  install_state.notify_id = nil
  for _, listener in ipairs(listeners) do
    pcall(listener, result)
  end
end

local function start_install(config, opts)
  opts = opts or {}
  local lib_path = runtime_lib_path(config)
  if not lib_path then
    return false, "arkbridge runtime library path is not configured"
  end

  if vim.fn.executable(vim.env.ARK_NVIM_R_BIN or "R") ~= 1 then
    return false, "R is not available to install pane-side arkbridge runtime"
  end

  if vim.fn.exists("*jobstart") ~= 1 then
    return false, "this Neovim does not support jobstart(), so arkbridge install is unavailable"
  end

  if install_state.running then
    if type(opts.on_complete) == "function" then
      install_state.listeners[#install_state.listeners + 1] = opts.on_complete
    end
    if opts.background ~= true then
      install_state.background = false
    end
    if opts.user_initiated == true then
      install_state.user_initiated = true
    end
    return true, nil
  end

  install_state.listeners = {}
  if type(opts.on_complete) == "function" then
    install_state.listeners[#install_state.listeners + 1] = opts.on_complete
  end
  install_state.running = true
  install_state.background = opts.background == true
  install_state.user_initiated = opts.user_initiated == true
  install_state.started_at = monotonic_ms()
  install_state.output = {}

  if not install_state.background or install_state.user_initiated then
    notify("Installing pane-side arkbridge runtime...", vim.log.levels.INFO, {
      hide_from_history = true,
    })
  end

  local source_mtime = tonumber(opts.source_mtime) or 0
  local pkg_path = normalize_path(config.session_pkg_path)
  local stamp = stamp_path(lib_path)
  if not pkg_path or not stamp then
    install_state.running = false
    install_state.started_at = nil
    install_state.notify_id = nil
    return false, "arkbridge install paths are invalid"
  end

  local cmd = {
    vim.env.ARK_NVIM_R_BIN or "R",
    "--slave",
    "--no-restore",
    "--no-save",
    "--no-site-file",
    "--no-init-file",
    "-f",
    INSTALL_SCRIPT,
    "--args",
    pkg_path,
    lib_path,
    stamp,
    tostring(source_mtime),
  }

  local job_id = vim.fn.jobstart(cmd, {
    cwd = ROOT,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_stderr = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local ok = code == 0
          and dir_exists(installed_package_dir(lib_path))
          and type(current_install_source_mtime(lib_path)) == "number"
        finish_install({
          ok = ok,
        })
      end)
    end,
  })

  if job_id <= 0 then
    install_state.running = false
    install_state.background = false
    install_state.user_initiated = false
    install_state.started_at = nil
    install_state.notify_id = nil
    return false, "failed to start arkbridge install"
  end

  return true, nil
end

function M.runtime_lib_path(config)
  return runtime_lib_path(config)
end

function M.ensure_current_runtime(config, opts)
  opts = opts or {}

  local lib_path = runtime_lib_path(config)
  if not lib_path then
    return nil, "arkbridge runtime library path is not configured"
  end

  local newest_mtime, newest_path = newest_source_state()
  local installed_path = installed_package_dir(lib_path)
  local installed_exists = dir_exists(installed_path)
  local installed_source_mtime = current_install_source_mtime(lib_path) or 0
  local stale = opts.force == true
    or not installed_exists
    or installed_source_mtime == 0
    or (type(newest_mtime) == "number" and newest_mtime > installed_source_mtime)
  local cache_key = table.concat({
    lib_path,
    tostring(installed_source_mtime),
    tostring(newest_mtime or 0),
  }, "::")

  if not stale and checked[cache_key] then
    return true, nil
  end

  if not stale then
    checked[cache_key] = true
    return true, nil
  end

  local ok, install_err = start_install(config, {
    source_mtime = newest_mtime,
    on_complete = (not installed_exists or opts.force == true) and opts.on_build_complete or nil,
    background = installed_exists and opts.force ~= true,
    user_initiated = opts.user_initiated == true,
  })
  if not ok then
    if installed_exists and opts.force ~= true then
      checked[cache_key] = true
      vim.schedule(function()
        notify(
          string.format(
            "background arkbridge install could not start; using current runtime (%s)",
            tostring(install_err)
          ),
          vim.log.levels.WARN
        )
      end)
      return true, nil
    end

    return nil, string.format(
      "arkbridge runtime is stale relative to %s and install failed to start: %s",
      newest_path or "bridge sources",
      tostring(install_err)
    )
  end

  if installed_exists and opts.force ~= true then
    return true, nil
  end

  return nil, {
    kind = "build_pending",
    message = "Installing pane-side arkbridge runtime...",
  }
end

function M.build_session_runtime(config, opts)
  opts = opts or {}
  local newest_mtime = select(1, newest_source_state())
  return start_install(config, {
    source_mtime = newest_mtime,
    on_complete = opts.on_complete,
    background = false,
    user_initiated = true,
  })
end

return M
