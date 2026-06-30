vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(60000, "ark_help_r_operator_tmux_popup")

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_help_r_operator_tmux_popup")
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

local popup_calls = {}
local help_topic_calls = {}
local parent_rpc_calls = {}
local notifications = {}
local hook_probe = nil
local post_help_probe = nil

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

local function diagnostic_status()
  local ok, status = pcall(function()
    return require("ark").status({ include_lsp = true })
  end)
  if ok then
    return status
  end
  return tostring(status)
end

local function fail_with_diagnostics(message, pane_id)
  ark_test.fail(message .. "\n" .. vim.inspect({
    parent_rpc_calls = parent_rpc_calls,
    help_topic_calls = help_topic_calls,
    popup_calls = popup_calls,
    hook_probe = hook_probe,
    post_help_probe = post_help_probe,
    notifications = notifications,
    status = diagnostic_status(),
    pane = capture_pane(pane_id),
  }))
end

local session = require("ark.session")
local original_help_popup = session.help_popup
session.help_popup = function(_opts, text, popup_opts)
  popup_calls[#popup_calls + 1] = {
    text = text,
    opts = popup_opts,
  }
  return true, nil
end

local ark = require("ark")
local original_help_topic = ark.help_topic
ark.help_topic = function(topic, bufnr)
  local call = {
    topic = topic,
    bufnr = bufnr,
    filetype = type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil,
    name = type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or nil,
  }
  help_topic_calls[#help_topic_calls + 1] = call

  local ok, value, err = pcall(original_help_topic, topic, bufnr)
  call.ok = ok
  call.value = value
  call.err = err
  if not ok then
    error(value, 0)
  end
  return value, err
end

local original_parent_rpc = nil

local ok, err = xpcall(function()
  -- Regression: a real managed R pane evaluating `?lm` should ask parent
  -- Neovim to open ArkHelp. The console input itself is not intercepted.
  local test_file = vim.fs.normalize(run_tmpdir .. "/ark_help_r_operator_tmux_popup.R")
  local pane_id = ark_test.setup_managed_buffer(test_file, { "lm" }, {
    help = {
      display = "tmux_popup",
      popup = {
        width = "80%",
        height = "70%",
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

  original_parent_rpc = _G.__ark_nvim_help_rpc
  if type(original_parent_rpc) ~= "function" then
    fail_with_diagnostics("parent ArkHelp RPC function was not registered", pane_id)
  end
  _G.__ark_nvim_help_rpc = function(topic)
    parent_rpc_calls[#parent_rpc_calls + 1] = {
      topic = topic,
    }
    return original_parent_rpc(topic)
  end

  local probe_marker = "ARKHELP_HOOK_PROBE"
  ark_test.tmux({
    "send-keys",
    "-t",
    pane_id,
    "local({ .installed <- exists('?', envir=.GlobalEnv, inherits=FALSE);"
      .. " .same <- FALSE;"
      .. " if (.installed && exists('.ark_help_operator', envir=asNamespace('arkbridge'), inherits=FALSE))"
      .. " .same <- identical(get('?', envir=.GlobalEnv), get('.ark_help_operator', envir=asNamespace('arkbridge')));"
      .. " cat("
      .. vim.inspect(probe_marker)
      .. ","
      .. " ' installed=', .installed,"
      .. " ' same=', .same,"
      .. " ' parent=', nzchar(Sys.getenv('ARK_NVIM_PARENT_SERVER')),"
      .. " ' target=', arkbridge:::.ark_help_hook_target_available(),"
      .. " '\\n', sep=''); flush.console() })",
    "Enter",
  })
  local probed = vim.wait(5000, function()
    local capture = capture_pane(pane_id) or ""
    local line = capture:match(probe_marker .. "[^\r\n]*")
    if line then
      hook_probe = line
      return true
    end
    return false
  end, 100, false)
  if not probed then
    fail_with_diagnostics("timed out waiting for R hook probe", pane_id)
  end

  ark_test.tmux({ "send-keys", "-t", pane_id, "?lm", "Enter" })

  local opened = vim.wait(15000, function()
    return #popup_calls == 1
  end, 100, false)
  if not opened then
    fail_with_diagnostics("timed out waiting for R ?lm to open ArkHelp popup", pane_id)
  end

  local post_marker = "ARKHELP_POST_HELP"
  ark_test.tmux({
    "send-keys",
    "-t",
    pane_id,
    "local({ .err <- arkbridge:::.ark_help_hook_state$last_error;"
      .. " if (is.null(.err)) .err <- '<NULL>';"
      .. " cat("
      .. vim.inspect(post_marker)
      .. ", ' last_error=', .err, '\\n', sep=''); flush.console() })",
    "Enter",
  })
  vim.wait(5000, function()
    local capture = capture_pane(pane_id) or ""
    local line = capture:match(post_marker .. "[^\r\n]*")
    if line then
      post_help_probe = line
      return true
    end
    return false
  end, 100, false)

  local popup = popup_calls[1]
  if not popup.text:find("Fitting Linear Models", 1, true) then
    fail_with_diagnostics("expected popup help text for stats::lm, got " .. vim.inspect(popup), pane_id)
  end
  if popup.opts.title ~= "ArkHelp: lm" then
    fail_with_diagnostics("unexpected ArkHelp popup title: " .. vim.inspect(popup.opts), pane_id)
  end
  if popup.opts.viewer ~= "nvim" then
    fail_with_diagnostics("R ?lm should use the default Neovim popup viewer, got " .. vim.inspect(popup.opts), pane_id)
  end

  local pane_text = capture_pane(pane_id) or ""
  if pane_text:find("package:stats", 1, true) or pane_text:find("Fitting Linear Models", 1, true) then
    fail_with_diagnostics("R ?lm opened ArkHelp but still fell back to base terminal help", pane_id)
  end
end, debug.traceback)

if original_parent_rpc ~= nil then
  _G.__ark_nvim_help_rpc = original_parent_rpc
end
ark.help_topic = original_help_topic
session.help_popup = original_help_popup
vim.notify = original_notify
stop_watchdog()

if not ok then
  error(err, 0)
end
