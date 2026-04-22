local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("runtime_extractor"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/runtime_extractor_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/runtime_extractor_state")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/runtime_extractor.R")
local stop_watchdog = ark_test.start_watchdog(90000, "full_config_runtime_extractor_tui")
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

local function latest_matching(predicate)
  local events = read_trace()
  for index = #events, 1, -1 do
    if predicate(events[index]) then
      return events[index]
    end
  end
end

local function pane_lines(pane_id)
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return vim.split(capture, "\n", { plain = true, trimempty = false })
end

local function pane_contains(pane_id, pattern)
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find(pattern, 1, true) ~= nil
end

local function session_panes()
  local output = tmux({ "list-panes", "-t", session_name, "-F", "#{pane_id}\t#{pane_active}\t#{pane_current_command}" })
  local panes = {}
  for line in output:gmatch("[^\n]+") do
    local pane_id, active, command = line:match("^([^\t]+)\t([^\t]+)\t(.+)$")
    if pane_id then
      panes[#panes + 1] = {
        pane_id = pane_id,
        active = active == "1",
        command = command,
      }
    end
  end
  return panes
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
    vim.fn.shellescape(init_path),
    vim.fn.shellescape(buffer_path),
    "-c",
    "'set shadafile=NONE'",
    "-c",
    "'luafile " .. repo_root .. "/tests/e2e/tui_blink_trace.lua'",
  }, " ")

  tmux({ "new-session", "-d", "-s", session_name, nvim_cmd })

  ark_test.wait_for("initial trace load", 15000, function()
    return latest_matching(function(event)
      return event.label == "loaded"
    end) ~= nil
  end)

  ark_test.wait_for("ark panes ready", 30000, function()
    local panes = session_panes()
    if #panes < 2 then
      return false
    end
    for _, pane in ipairs(panes) do
      if pane.command == "sh" and pane_contains(pane.pane_id, ">") then
        return true
      end
    end
    return false
  end)

  local nvim_pane, r_pane
  for _, pane in ipairs(session_panes()) do
    if pane.active then
      nvim_pane = pane.pane_id
    elseif pane.command == "sh" then
      r_pane = pane.pane_id
    end
  end

  if not nvim_pane or not r_pane then
    ark_test.fail("failed to identify Neovim and R panes: " .. vim.inspect(session_panes()))
  end

  tmux({ "send-keys", "-t", r_pane, 'mylist <- list(x = 1, y = iris)', "Enter" })
  ark_test.wait_for("runtime mylist in R pane", 10000, function()
    local capture = tmux({ "capture-pane", "-p", "-t", r_pane })
    return capture:find("mylist <- list", 1, true) ~= nil and capture:find("iris", 1, true) ~= nil
  end)

  tmux({
    "send-keys",
    "-t",
    nvim_pane,
    "Escape",
    ":call setline(1, ['mylist <- list(x = 1, y = iris)', ''])",
    "Enter",
    "2G$",
    "A",
    "mylist",
  })

  ark_test.wait_for("typed mylist in Neovim pane", 10000, function()
    local lines = pane_lines(nvim_pane)
    return lines[2] ~= nil and lines[2]:find("mylist", 1, true) ~= nil
  end)

  tmux({ "send-keys", "-t", nvim_pane, "C-Space" })
  ark_test.wait_for("mylist completion ready", 10000, function()
    local event = latest_matching(function(candidate)
      local trigger = candidate.trigger or {}
      return candidate.label == "BlinkCmpShow"
        and (trigger.kind == "manual" or trigger.kind == "keyword")
        and candidate.line == "mylist"
    end)
    return event ~= nil
  end)

  tmux({ "send-keys", "-t", nvim_pane, "$" })

  local extractor_show = nil
  ark_test.wait_for("runtime extractor completion show", 10000, function()
    extractor_show = latest_matching(function(candidate)
      local trigger = candidate.trigger or {}
      return candidate.label == "BlinkCmpShow"
        and trigger.kind == "trigger_character"
        and trigger.character == "$"
        and candidate.line == "mylist$"
    end)
    return extractor_show ~= nil
  end)

  local labels = {}
  local foreign = {}
  for _, item in ipairs(extractor_show.items or {}) do
    labels[#labels + 1] = item.label
    if item.source_id ~= "ark_lsp" then
      foreign[#foreign + 1] = item
    end
  end

  if not vim.tbl_contains(labels, "x") or not vim.tbl_contains(labels, "y") then
    ark_test.fail("runtime extractor show missing x/y: " .. vim.inspect(extractor_show))
  end

  if #foreign > 0 then
    ark_test.fail("non-Ark providers leaked into runtime extractor TUI completion: " .. vim.inspect({
      foreign = foreign,
      extractor_show = extractor_show,
    }))
  end

  vim.print({
    extractor_show = extractor_show,
  })
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
