local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("nvim_console_blink"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_blink_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_blink_state")
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_blink")
local fake_lsp = vim.fs.normalize(run_tmpdir .. "/fake-lsp")
local fake_r = vim.fs.normalize(run_tmpdir .. "/fake-r")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")
local stop_watchdog = ark_test.start_watchdog(90000, "nvim_console_blink_tui")
local init_path = vim.env.ARK_TEST_NVIM_INIT

if type(init_path) ~= "string" or init_path == "" or init_path == "NONE" then
  init_path = vim.fs.normalize(repo_root .. "/tests/e2e/init.lua")
end

vim.fn.mkdir(run_tmpdir, "p")
vim.fn.mkdir(status_dir, "p")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, fake_r)
vim.fn.setfperm(fake_r, "rwxr-xr-x")

vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import json",
  "import sys",
  "",
  "documents = {}",
  "",
  "def read_message():",
  "    header = b''",
  "    while b'\\r\\n\\r\\n' not in header:",
  "        chunk = sys.stdin.buffer.read(1)",
  "        if not chunk:",
  "            return None",
  "        header += chunk",
  "    headers, rest = header.split(b'\\r\\n\\r\\n', 1)",
  "    length = 0",
  "    for line in headers.decode('ascii').split('\\r\\n'):",
  "        if line.lower().startswith('content-length:'):",
  "            length = int(line.split(':', 1)[1].strip())",
  "    body = rest + sys.stdin.buffer.read(length - len(rest))",
  "    return json.loads(body.decode('utf-8'))",
  "",
  "def send(payload):",
  "    body = json.dumps(payload).encode('utf-8')",
  "    sys.stdout.buffer.write(b'Content-Length: %d\\r\\n\\r\\n' % len(body))",
  "    sys.stdout.buffer.write(body)",
  "    sys.stdout.buffer.flush()",
  "",
  "while True:",
  "    message = read_message()",
  "    if message is None:",
  "        break",
  "    method = message.get('method')",
  "    request_id = message.get('id')",
  "    params = message.get('params') or {}",
  "    if method == 'textDocument/didOpen':",
  "        text_document = params.get('textDocument') or {}",
  "        documents[text_document.get('uri', '')] = text_document.get('text', '')",
  "        continue",
  "    if method == 'textDocument/didChange':",
  "        text_document = params.get('textDocument') or {}",
  "        uri = text_document.get('uri', '')",
  "        changes = params.get('contentChanges') or []",
  "        if changes and 'text' in changes[-1]:",
  "            documents[uri] = changes[-1].get('text', '')",
  "        continue",
  "    if request_id is None:",
  "        continue",
  "    if method == 'initialize':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'capabilities': {'textDocumentSync': 1, 'completionProvider': {'triggerCharacters': ['$', ':', '\"', '[', '/', '@']}}}})",
  "    elif method == 'textDocument/completion':",
  "        labels = ['console_blink_item', 'console_library_item', 'console_namespace_item', 'console_subset_item', 'console_comparison_item', 'src/console_path_item', 'mtcars']",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'isIncomplete': False, 'items': [{'label': label, 'kind': 6} for label in labels]}})",
  "    else:",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': None})",
}, fake_lsp)
vim.fn.setfperm(fake_lsp, "rwxr-xr-x")

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

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(trace_path)

  local nvim_cmd = table.concat({
    "XDG_STATE_HOME=" .. vim.fn.shellescape(state_home),
    "ARK_TUI_TRACE_LOG=" .. vim.fn.shellescape(trace_path),
    "ARK_REPO_ROOT=" .. vim.fn.shellescape(repo_root),
    "ARK_NVIM_LSP_BIN=" .. vim.fn.shellescape(fake_lsp),
    "ARK_NVIM_LAUNCHER=" .. vim.fn.shellescape(fake_r),
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
  local function request_console_ready_snapshot()
    local now = monotonic_ms()
    if now - last_snapshot_ms < 500 then
      return
    end
    last_snapshot_ms = now
    tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceSnapshot console-ready", "Enter" })
  end

  request_console_ready_snapshot()
  ark_test.wait_for("console ark_lsp attached", 15000, function()
    local ready = latest_matching(function(candidate)
      return candidate.label == "ArkTraceSnapshot"
        and candidate.args == "console-ready"
        and tonumber(candidate.ark_clients or 0) >= 1
    end) ~= nil
    if not ready then
      request_console_ready_snapshot()
    end
    return ready
  end)

  local function type_console_input(text)
    tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceClearInput", "Enter" })
    tmux({ "send-keys", "-l", "-t", nvim_pane, text })
  end

  local function trigger_completion(trigger)
    tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceShowTrigger " .. trigger, "Enter" })
  end

  local function assert_console_completion(case)
    type_console_input(case.text)
    if case.trigger then
      trigger_completion(case.trigger)
    end

    local completion_show = nil
    ark_test.wait_for(case.name, 15000, function()
      completion_show = latest_matching(function(candidate)
      if candidate.label ~= "BlinkCmpShow" then
        return false
      end
      if candidate.line ~= case.text then
        return false
      end
      for _, item in ipairs(candidate.items or {}) do
        if item.label == case.label and item.client_name == "ark_lsp" then
          return true
        end
      end
      return false
      end)
      return completion_show ~= nil
    end)

    return completion_show
  end

  local completion_cases = {
    { name = "console Blink mtcars dollar completion", text = "mtcars$", label = "console_blink_item" },
    { name = "console Blink library quote completion", text = 'library("', trigger = '"', label = "console_library_item" },
    { name = "console Blink namespace completion", text = "pkg::", label = "console_namespace_item" },
    { name = "console Blink subset string completion", text = 'mtcars[, c("', trigger = '"', label = "console_subset_item" },
    { name = "console Blink comparison string completion", text = 'species == "', trigger = '"', label = "console_comparison_item" },
    { name = "console Blink path completion", text = 'read.csv("src/', trigger = "/", label = "src/console_path_item" },
    { name = "console Blink named argument value completion", text = "corx::corx(data = mtca", label = "mtcars" },
  }

  local completion_shows = {}
  for _, case in ipairs(completion_cases) do
    completion_shows[case.name] = assert_console_completion(case)
    if case.text == "mtcars$" then
      tmux({ "send-keys", "-t", nvim_pane, "Enter" })
      ark_test.wait_for("console Enter accepts Blink completion", 15000, function()
        return latest_matching(function(candidate)
          return candidate.label == "TextChangedI"
            and type(candidate.line) == "string"
            and candidate.line:find("console_blink_item", 1, true) ~= nil
        end) ~= nil
      end)
    end
  end

  vim.print({
    completion_shows = completion_shows,
  })
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
