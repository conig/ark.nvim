local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("nvim_console_real_blink_value"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_real_blink_value_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_real_blink_value_state")
local status_dir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_real_blink_value_status")
local launcher = vim.fs.normalize(repo_root .. "/scripts/ark-r-launcher.sh")
local lsp_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-lsp")
local stop_watchdog = ark_test.start_watchdog(120000, "nvim_console_real_blink_value_completion_tui")
local init_path = vim.env.ARK_TEST_NVIM_INIT

if type(init_path) ~= "string" or init_path == "" or init_path == "NONE" then
  init_path = vim.fs.normalize(repo_root .. "/tests/e2e/init.lua")
end

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_real_blink_value_completion_tui")
end
if vim.fn.executable(launcher) ~= 1 then
  ark_test.fail("Ark R launcher is not executable: " .. launcher)
end
ark_test.assert_fresh_detached_lsp_binary(lsp_bin)

vim.fn.mkdir(status_dir, "p")

local function tmux(args, allow_failure)
  local command = { "tmux" }
  local explicit_socket = vim.env.ARK_TMUX_SOCKET
  if type(explicit_socket) == "string" and explicit_socket ~= "" then
    command[#command + 1] = "-S"
    command[#command + 1] = explicit_socket
  end

  local output = vim.fn.system(vim.list_extend(command, args))
  if vim.v.shell_error ~= 0 and not allow_failure then
    ark_test.fail("tmux command failed: " .. output)
  end
  return output
end

local function cleanup()
  tmux({ "kill-session", "-t", session_name }, true)
end

local function read_trace()
  if vim.fn.filereadable(trace_path) ~= 1 then
    return {}
  end

  local events = {}
  for _, line in ipairs(vim.fn.readfile(trace_path)) do
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" then
        events[#events + 1] = decoded
      end
    end
  end
  return events
end

local function latest_matching(predicate)
  local events = read_trace()
  for index = #events, 1, -1 do
    if predicate(events[index]) then
      return events[index]
    end
  end
end

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(trace_path)

  local nvim_cmd = table.concat({
    "XDG_STATE_HOME=" .. vim.fn.shellescape(state_home),
    "ARK_TUI_TRACE_LOG=" .. vim.fn.shellescape(trace_path),
    "ARK_REPO_ROOT=" .. vim.fn.shellescape(repo_root),
    "ARK_NVIM_LSP_BIN=" .. vim.fn.shellescape(lsp_bin),
    "ARK_NVIM_LAUNCHER=" .. vim.fn.shellescape(launcher),
    "ARK_STATUS_DIR=" .. vim.fn.shellescape(status_dir),
    "ARK_TMUX_SOCKET=" .. vim.fn.shellescape(vim.env.ARK_TMUX_SOCKET or ""),
    "env -u ARK_TMUX_ANCHOR_PANE -u ARK_TMUX_SESSION",
    "nvim",
    "-n",
    "-u",
    vim.fn.shellescape(init_path),
    "-c",
    "'set shadafile=NONE'",
    "-c",
    "'luafile " .. repo_root .. "/tests/e2e/tui_blink_trace.lua'",
  }, " ")

  tmux({ "new-session", "-d", "-s", session_name, nvim_cmd })

  ark_test.wait_for("trace load", 15000, function()
    return latest_matching(function(event)
      return event.label == "loaded"
    end) ~= nil
  end)

  local pane_output = tmux({ "list-panes", "-t", session_name, "-F", "#{pane_id}\t#{pane_active}" })
  local nvim_pane = pane_output:match("^([^\t]+)\t1")
  if not nvim_pane then
    ark_test.fail("failed to identify active Neovim pane: " .. pane_output)
  end

  tmux({ "send-keys", "-t", nvim_pane, "Escape", ":Ark console", "Enter" })

  ark_test.wait_for("console buffer opened", 15000, function()
    return latest_matching(function(candidate)
      return candidate.label == "TextChangedI"
        and type(candidate.line) == "string"
        and candidate.line == ""
    end) ~= nil
  end)

  local function monotonic_ms()
    return math.floor(vim.uv.hrtime() / 1e6)
  end

  local last_snapshot_ms = 0
  local function request_snapshot()
    local now = monotonic_ms()
    if now - last_snapshot_ms < 500 then
      return
    end
    last_snapshot_ms = now
    tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceSnapshot console-live-ready", "Enter" })
  end

  request_snapshot()
  ark_test.wait_for("console live completion runtime ready", 45000, function()
    local ready = latest_matching(function(candidate)
      local status = type(candidate.ark_status) == "table" and candidate.ark_status or {}
      return candidate.label == "ArkTraceSnapshot"
        and candidate.args == "console-live-ready"
        and tonumber(candidate.ark_clients or 0) >= 1
        and status.lsp_available == true
        and tonumber(status.console_scope_count or 0) > 0
        and tonumber(status.library_path_count or 0) > 0
    end) ~= nil
    if not ready then
      request_snapshot()
    end
    return ready
  end)

  local text = "corx::corx(data = mtca"
  tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceClearInput", "Enter" })
  tmux({ "send-keys", "-l", "-t", nvim_pane, text })

  local completion_show = nil
  ark_test.wait_for("real console Blink mtcars value completion", 30000, function()
    completion_show = latest_matching(function(candidate)
      if candidate.label ~= "BlinkCmpShow" or type(candidate.line) ~= "string" then
        return false
      end
      if candidate.line:sub(1, #text) ~= text then
        return false
      end
      for _, item in ipairs(candidate.items or {}) do
        if item.label == "mtcars" and item.client_name == "ark_lsp" then
          return true
        end
      end
      return false
    end)
    return completion_show ~= nil
  end)

  vim.print({
    completion_show = completion_show,
  })
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
