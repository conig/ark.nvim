local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("rmd_output_enter_after_leader_y"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/rmd_output_enter_after_leader_y_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/rmd_output_enter_after_leader_y_state")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/rmd_output_enter_after_leader_y.Rmd")
local stop_watchdog = ark_test.start_watchdog(90000, "full_config_rmd_output_enter_after_leader_y_tui")
local init_path = vim.env.ARK_TEST_NVIM_INIT
local expected_output_labels = {
  "html_document",
  "pdf_document",
  "word_document",
  "beamer_presentation",
  "ioslides_presentation",
  "slidy_presentation",
}

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

local function latest_after(ts_ms, predicate)
  return latest_matching(function(event)
    return tonumber(event.ts_ms or -1) >= ts_ms and predicate(event)
  end)
end

local function pane_contains(pane_id, pattern)
  local capture = tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find(pattern, 1, true) ~= nil
end

local function matches_expected_output_items(items)
  if #items ~= #expected_output_labels then
    return false
  end

  for index, item in ipairs(items) do
    if item.label ~= expected_output_labels[index] or item.client_name ~= "ark_lsp" then
      return false
    end
  end

  return true
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

  -- Reproduce the user's real flow under the full config: create frontmatter
  -- with <leader>y, type `output: ` in the blank YAML line, then press Enter.
  tmux({ "send-keys", "-t", nvim_pane, "Escape", "Space", "y" })

  local yaml_insert = nil
  ark_test.wait_for("yaml frontmatter insert", 10000, function()
    yaml_insert = latest_matching(function(candidate)
      return candidate.label == "InsertEnter"
        and candidate.line == ""
        and type(candidate.cursor) == "table"
        and candidate.cursor[1] == 2
    end)
    return yaml_insert ~= nil
  end)

  tmux({ "send-keys", "-t", nvim_pane, "-l", "output: " })

  local completion_show = nil
  ark_test.wait_for("frontmatter output completion", 10000, function()
    completion_show = latest_matching(function(candidate)
      if candidate.label ~= "BlinkCmpShow" or candidate.line ~= "output: " then
        return false
      end

      return matches_expected_output_items(candidate.items or {})
    end)
    return completion_show ~= nil
  end)

  tmux({ "send-keys", "-t", nvim_pane, "Enter" })

  local after_enter_snapshot = nil
  ark_test.wait_for("after enter snapshot", 5000, function()
    tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceSnapshot after_enter", "Enter" })
    after_enter_snapshot = latest_matching(function(candidate)
      return candidate.label == "ArkTraceSnapshot"
        and candidate.args == "after_enter"
    end)
    return after_enter_snapshot ~= nil and tonumber(after_enter_snapshot.ts_ms or -1) >= tonumber(completion_show.ts_ms or 0)
  end)

  local hide_event = latest_after(completion_show.ts_ms, function(candidate)
    return candidate.label == "BlinkCmpHide"
  end)

  if after_enter_snapshot.line ~= "output: html_document" then
    ark_test.fail(vim.inspect({
      error = "frontmatter output completion left unexpected trailing space after Enter",
      yaml_insert = yaml_insert,
      completion_show = completion_show,
      hide_event = hide_event,
      after_enter_snapshot = after_enter_snapshot,
    }))
  end

  if hide_event == nil then
    ark_test.fail(vim.inspect({
      error = "frontmatter output completion menu did not hide after Enter",
      yaml_insert = yaml_insert,
      completion_show = completion_show,
      after_enter_snapshot = after_enter_snapshot,
    }))
  end

  vim.print({
    yaml_insert = yaml_insert,
    completion_show = completion_show,
    hide_event = hide_event,
    after_enter_snapshot = after_enter_snapshot,
  })
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
