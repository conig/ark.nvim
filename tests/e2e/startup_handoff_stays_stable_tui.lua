local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("startup_handoff_stays_stable"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/startup_handoff_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/startup_handoff_state")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/startup_handoff.R")
local stop_watchdog = ark_test.start_watchdog(90000, "startup_handoff_stays_stable_tui")

local function tmux(args, allow_failure)
  local command = { "tmux" }
  local explicit_socket = vim.env.ARK_TMUX_SOCKET
  if type(explicit_socket) == "string" and explicit_socket ~= "" then
    command[#command + 1] = "-S"
    command[#command + 1] = explicit_socket
  else
    local tmux_env = vim.env.TMUX
    if type(tmux_env) == "string" and tmux_env ~= "" then
      local socket = vim.split(tmux_env, ",", { plain = true })[1]
      if type(socket) == "string" and socket ~= "" then
        command[#command + 1] = "-S"
        command[#command + 1] = socket
      end
    end
  end

  local output = vim.fn.system(vim.list_extend(command, args))
  if vim.v.shell_error ~= 0 and not allow_failure then
    ark_test.fail("tmux command failed: " .. output)
  end
  return output
end

local function read_trace()
  if vim.fn.filereadable(trace_path) ~= 1 then
    return {}
  end

  local lines = vim.fn.readfile(trace_path)
  local events = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and type(decoded) == "table" then
        events[#events + 1] = decoded
      end
    end
  end
  return events
end

local function cleanup()
  tmux({ "kill-session", "-t", session_name }, true)
end

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(trace_path)

  local nvim_cmd = table.concat({
    "XDG_STATE_HOME=" .. vim.fn.shellescape(state_home),
    "ARK_TUI_TRACE_LOG=" .. vim.fn.shellescape(trace_path),
    "ARK_REPO_ROOT=" .. vim.fn.shellescape(repo_root),
    "ARK_TMUX_SOCKET=" .. vim.fn.shellescape(vim.env.ARK_TMUX_SOCKET or ""),
    "env -u ARK_TMUX_ANCHOR_PANE -u ARK_TMUX_SESSION",
    "nvim",
    "-n",
    "-u",
    vim.fn.shellescape(repo_root .. "/tests/e2e/init.lua"),
    vim.fn.shellescape(buffer_path),
    "-c",
    "'set shadafile=NONE'",
    "-c",
    "'luafile " .. repo_root .. "/tests/e2e/tui_startup_chatter_trace.lua'",
  }, " ")

  tmux({ "new-session", "-d", "-s", session_name, nvim_cmd })

  ark_test.wait_for("initial startup trace load", 15000, function()
    for _, event in ipairs(read_trace()) do
      if event.label == "loaded" then
        return true
      end
    end
    return false
  end)

  ark_test.wait_for("startup handoff trace settle", 15000, function()
    for _, event in ipairs(read_trace()) do
      if event.label == "tick:1500" then
        return true
      end
    end
    return false
  end)

  local events = read_trace()
  local unlocked_at = nil
  local degraded = {}

  for _, event in ipairs(events) do
    local status = type(event.status) == "table" and event.status or nil
    local startup = status and type(status.startup) == "table" and status.startup or nil
    local detached = status and type(status.detached) == "table" and status.detached or nil

    if unlocked_at == nil and startup and startup.unlocked == true then
      unlocked_at = tonumber(event.ts_ms)
    end

    if unlocked_at ~= nil and tonumber(event.ts_ms) >= unlocked_at and detached then
      if detached.lastSessionUpdateStatus ~= "ready" or detached.lastSessionUpdateReplReady ~= true then
        degraded[#degraded + 1] = {
          label = event.label,
          ts_ms = event.ts_ms,
          detached = detached,
          startup = startup,
        }
      end
    end
  end

  if unlocked_at == nil then
    ark_test.fail("startup trace never reported an unlocked main buffer: " .. vim.inspect(events))
  end

  if #degraded > 0 then
    ark_test.fail("detached session regressed after startup unlock: " .. vim.inspect({
      unlocked_at = unlocked_at,
      degraded = degraded,
      events = events,
    }))
  end

  vim.print({
    unlocked_at = unlocked_at,
    events = events,
  })
end, debug.traceback)

cleanup()
stop_watchdog()

if not ok then
  error(err, 0)
end
