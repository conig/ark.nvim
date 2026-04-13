local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("extractor_rapid_select"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/extractor_rapid_select_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/extractor_rapid_select_state")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/extractor_rapid_select.R")
local stop_watchdog = ark_test.start_watchdog(90000, "full_config_extractor_rapid_select_tui")
local init_path = vim.env.ARK_TEST_NVIM_INIT

if type(init_path) ~= "string" or init_path == "" or init_path == "NONE" then
  init_path = vim.fs.normalize(repo_root .. "/tests/e2e/init.lua")
end

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

local function pane_contains(pane_id, pattern)
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find(pattern, 1, true) ~= nil
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
    vim.fn.shellescape(init_path),
    vim.fn.shellescape(buffer_path),
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

  ark_test.wait_for("managed R pane", 30000, function()
    local output = tmux({ "list-panes", "-t", session_name, "-F", "#{pane_id}\t#{pane_current_command}" })
    for line in output:gmatch("[^\n]+") do
      local pane_id, command = line:match("^([^\t]+)\t(.+)$")
      if pane_id and command == "sh" and pane_contains(pane_id, ">") then
        return true
      end
    end
    return false
  end)

  tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceSnapshot ready", "Enter" })
  ark_test.wait_for("ark lsp attached", 15000, function()
    local event = latest_matching(function(candidate)
      return candidate.label == "ArkTraceSnapshot"
        and candidate.args == "ready"
    end)
    return event ~= nil and tonumber(event.ark_clients or 0) >= 1
  end)

  tmux({
    "send-keys",
    "-t",
    nvim_pane,
    "Escape",
    ":call setline(1, [''])",
    "Enter",
    "gg0i",
    "mtcars",
    "Escape",
    "A",
    "$",
  })

  ark_test.wait_for("mtcars extractor menu", 10000, function()
    local event = latest_matching(function(candidate)
      local trigger = candidate.trigger or {}
      return candidate.label == "BlinkCmpShow"
        and candidate.line == "mtcars$"
        and trigger.kind == "trigger_character"
        and trigger.character == "$"
    end)
    return event ~= nil
  end)

  local start_ts = latest_matching(function(candidate)
    local trigger = candidate.trigger or {}
    return candidate.label == "BlinkCmpShow"
      and candidate.line == "mtcars$"
      and trigger.kind == "trigger_character"
      and trigger.character == "$"
  end).ts_ms

  tmux({ "send-keys", "-t", nvim_pane, "C-j", "C-j", "C-j", "C-j", "Escape" })

  ark_test.wait_for("rapid select insert leave", 10000, function()
    local event = latest_matching(function(candidate)
      return candidate.label == "InsertLeave" and (candidate.ts_ms or 0) > start_ts
    end)
    return event ~= nil
  end)

  local bad_events = {}
  for _, event in ipairs(read_trace()) do
    if (event.ts_ms or 0) > start_ts then
      if type(event.line) == "string" and event.line ~= "" and event.line ~= "mtcars$" then
        bad_events[#bad_events + 1] = {
          label = event.label,
          line = event.line,
          diagnostics = event.diagnostics,
        }
      end

      for _, diagnostic in ipairs(event.diagnostics or {}) do
        if diagnostic.message ~= "No symbol named 'mtcars' in scope." then
          bad_events[#bad_events + 1] = {
            label = event.label,
            line = event.line,
            diagnostic = diagnostic.message,
          }
        end
      end
    end
  end

  if #bad_events > 0 then
    ark_test.fail("rapid extractor selection mutated the buffer or produced garbage diagnostics: " .. vim.inspect(bad_events))
  end

  vim.print({
    status = "ok",
  })
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
