local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("rmd_inline_completion"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/rmd_inline_completion_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/rmd_inline_completion_state")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/rmd_inline_completion.Rmd")
local stop_watchdog = ark_test.start_watchdog(90000, "full_config_rmd_inline_function_completion_tui")
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

  vim.wait(1500, function()
    return false
  end, 50, false)

  tmux({
    "send-keys",
    "-t",
    nvim_pane,
    "Escape",
    ":call setline(1, ['---', 'title: \"Inline\"', '---', '', 'The row count is `r `.'])",
    "Enter",
    "5G",
    "$",
    "h",
    "i",
    "n",
  })

  ark_test.wait_for("typed inline n", 10000, function()
    local event = latest_matching(function(candidate)
      return candidate.label == "TextChangedI"
        and candidate.line == "The row count is `r n`."
    end)
    return event ~= nil
  end)

  local completion_show = nil
  ark_test.wait_for("inline nrow completion", 10000, function()
    completion_show = latest_matching(function(candidate)
      if candidate.label ~= "BlinkCmpShow" or candidate.line ~= "The row count is `r n`." then
        return false
      end

      local trigger = type(candidate.trigger) == "table" and candidate.trigger or nil
      if type(trigger) == "table" and trigger.initial_kind == "manual" then
        return false
      end

      for _, item in ipairs(candidate.items or {}) do
        if item.label == "nrow" and (item.client_name == "ark_lsp" or item.source_id == "ark_lsp") then
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
