vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(60000, "ark_view_r_function_tmux_popup")

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_view_r_function_tmux_popup")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")

vim.fn.mkdir(run_tmpdir, "p")
vim.fn.mkdir(status_dir, "p")

local function ensure_bridge_runtime_current()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, err = bridge.ensure_current_runtime(config, {
    on_build_complete = function(result)
      completed = result
    end,
    user_initiated = true,
  })
  if ok then
    return
  end

  if type(err) ~= "table" or err.kind ~= "build_pending" then
    ark_test.fail("failed to prepare pane-side arkbridge runtime: " .. vim.inspect(err))
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    ark_test.fail("timed out waiting for pane-side arkbridge runtime install: " .. vim.inspect(completed or err))
  end

  local retry_ok, retry_err = bridge.ensure_current_runtime(config, {})
  if not retry_ok then
    ark_test.fail("pane-side arkbridge runtime was not current after install: " .. vim.inspect(retry_err))
  end
end

ensure_bridge_runtime_current()

local view_calls = {}
local popup_calls = {}
local parent_rpc_calls = {}
local notifications = {}
local hook_probe = nil

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = tostring(message),
    level = level,
    opts = opts,
  }
  if type(original_notify) == "function" then
    return original_notify(message, level, opts)
  end
end

local function capture_pane(pane_id)
  if type(pane_id) ~= "string" or pane_id == "" then
    return nil
  end

  local ok, capture = pcall(function()
    return ark_test.tmux({ "capture-pane", "-p", "-S", "-200", "-t", pane_id })
  end)
  if ok then
    return capture
  end
  return tostring(capture)
end

local function fail_with_diagnostics(message, pane_id)
  ark_test.fail(message .. "\n" .. vim.inspect({
    parent_rpc_calls = parent_rpc_calls,
    view_calls = view_calls,
    popup_calls = popup_calls,
    hook_probe = hook_probe,
    notifications = notifications,
    pane = capture_pane(pane_id),
  }))
end

local ark = require("ark")
local original_view = ark.view
ark.view = function(expr, bufnr, opts)
  view_calls[#view_calls + 1] = {
    expr = expr,
    bufnr = bufnr,
    opts = opts,
  }
  return true, nil
end

local original_parent_rpc = nil

local ok, err = xpcall(function()
  -- Regression: a real managed R pane evaluating View(mtcars) must call the
  -- Ark R hook from the installed pane-side arkbridge package, not utils::View.
  local test_file = vim.fs.normalize(run_tmpdir .. "/ark_view_r_function_tmux_popup.R")
  local pane_id = ark_test.setup_managed_buffer(test_file, { "mtcars" }, {
    view = {
      display = "tmux_popup",
      popup = {
        width = "88%",
        height = "77%",
      },
    },
    tmux = {
      console_frontend = "raw",
      launcher = vim.fs.normalize(repo_root .. "/scripts/ark-r-launcher.sh"),
      session_pkg_path = vim.fs.normalize(repo_root .. "/packages/arkbridge"),
      startup_status_dir = status_dir,
      bridge_wait_ms = 10000,
    },
  })

  original_parent_rpc = _G.__ark_nvim_view_rpc
  if type(original_parent_rpc) ~= "function" then
    fail_with_diagnostics("parent ArkView RPC function was not registered", pane_id)
  end
  _G.__ark_nvim_view_rpc = function(expr)
    parent_rpc_calls[#parent_rpc_calls + 1] = {
      expr = expr,
    }
    return original_parent_rpc(expr)
  end

  local probe_marker = "ARKVIEW_HOOK_PROBE"
  ark_test.tmux({
    "send-keys",
    "-t",
    pane_id,
    "local({ .ns <- asNamespace('arkbridge');"
      .. " .installed <- exists('View', envir=.GlobalEnv, inherits=FALSE);"
      .. " .same <- FALSE;"
      .. " .utils_same <- FALSE;"
      .. " .has_request <- exists('.ark_request_neovim_view', envir=.ns, inherits=FALSE);"
      .. " if (.installed && exists('.ark_view_function', envir=.ns, inherits=FALSE))"
      .. " .same <- identical(get('View', envir=.GlobalEnv), get('.ark_view_function', envir=.ns));"
      .. " if (exists('.ark_utils_view_function', envir=.ns, inherits=FALSE))"
      .. " .utils_same <- identical(get('View', envir=asNamespace('utils')), get('.ark_utils_view_function', envir=.ns));"
      .. " cat("
      .. vim.inspect(probe_marker)
      .. ","
      .. " ' installed=', .installed,"
      .. " ' same=', .same,"
      .. " ' utils_same=', .utils_same,"
      .. " ' has_request=', .has_request,"
      .. " ' parent=', nzchar(Sys.getenv('ARK_NVIM_PARENT_SERVER')),"
      .. " '\\n', sep=''); flush.console() })",
    "Enter",
  })
  local probed = vim.wait(5000, function()
    local capture = capture_pane(pane_id) or ""
    if capture:find("ARKVIEW_HOOK_%s*PROBE%s+installed=TRUE") and capture:find("parent=TRUE", 1, true) then
      hook_probe = capture
      return true
    end
    return false
  end, 100, false)
  if not probed then
    fail_with_diagnostics("timed out waiting for R View hook probe", pane_id)
  end
  -- tmux capture can soft-wrap long probe lines in the middle of tokens.
  local compact_probe = hook_probe:gsub("%s+", "")
  if not compact_probe:find("installed=TRUE", 1, true)
    or not compact_probe:find("same=TRUE", 1, true)
    or not compact_probe:find("utils_same=TRUE", 1, true)
    or not compact_probe:find("has_request=TRUE", 1, true)
  then
    fail_with_diagnostics("installed R runtime did not expose the ArkView hook: " .. tostring(hook_probe), pane_id)
  end

  ark_test.tmux({ "send-keys", "-t", pane_id, "View(mtcars)", "Enter" })

  local opened = vim.wait(15000, function()
    return #view_calls == 1
  end, 100, false)
  if not opened then
    fail_with_diagnostics("timed out waiting for R View(mtcars) to open ArkView", pane_id)
  end

  if parent_rpc_calls[1].expr ~= "mtcars" then
    fail_with_diagnostics("expected parent View RPC for mtcars, got " .. vim.inspect(parent_rpc_calls), pane_id)
  end
  if view_calls[1].expr ~= "mtcars" then
    fail_with_diagnostics("expected ArkView dispatch for mtcars, got " .. vim.inspect(view_calls), pane_id)
  end

  local pane = capture_pane(pane_id) or ""
  if pane:find("unable to start data viewer", 1, true) or pane:find("invalid 'x' argument", 1, true) then
    fail_with_diagnostics("R View(mtcars) fell back to utils::View", pane_id)
  end
end, debug.traceback)

if original_parent_rpc ~= nil then
  _G.__ark_nvim_view_rpc = original_parent_rpc
end
ark.view = original_view
vim.notify = original_notify

if not ok then
  error(err, 0)
end

vim.print({
  ark_view_r_function_tmux_popup = "ok",
})

stop_watchdog()
