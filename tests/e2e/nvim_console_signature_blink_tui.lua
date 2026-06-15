local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("nvim_console_sig_blink"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_sig_blink_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_sig_blink_state")
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_sig_blink")
local fake_lsp = vim.fs.normalize(run_tmpdir .. "/fake-lsp")
local fake_r = vim.fs.normalize(run_tmpdir .. "/fake-r")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")
local stop_watchdog = ark_test.start_watchdog(90000, "nvim_console_signature_blink_tui")
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
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'capabilities': {'textDocumentSync': 1, 'completionProvider': {'triggerCharacters': ['m']}, 'signatureHelpProvider': {'triggerCharacters': ['(', ',', '=']}}}})",
  "    elif method == 'textDocument/completion':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'isIncomplete': False, 'items': [{'label': 'mtcars', 'kind': 6}]}})",
  "    elif method == 'textDocument/signatureHelp':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'signatures': [{'label': 'fake_sig(x, y)', 'parameters': [{'label': [9, 10]}, {'label': [12, 13]}], 'activeParameter': 0}], 'activeSignature': 0, 'activeParameter': 0}})",
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

local function has_signature_float(event)
  if type(event) ~= "table" then
    return false
  end
  for _, float in ipairs(event.floats or {}) do
    local text = table.concat(float.lines or {}, "\n")
    if text:find("fake_sig", 1, true) then
      return true
    end
  end
  return false
end

local function has_completion_menu(event)
  if type(event) ~= "table" then
    return false
  end
  if event.visible ~= true and event.menu_open ~= true then
    return false
  end
  for _, item in ipairs(event.items or {}) do
    if item.label == "mtcars" then
      return true
    end
  end
  return false
end

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(trace_path)

  local nvim_cmd = table.concat({
    "XDG_STATE_HOME=" .. vim.fn.shellescape(state_home),
    "XDG_DATA_HOME=" .. vim.fn.shellescape(vim.env.XDG_DATA_HOME or vim.fn.stdpath("data")),
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

  ark_test.wait_for("console ark_lsp attached", 15000, function()
    tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceSnapshot console-ready", "Enter" })
    return latest_matching(function(candidate)
      return candidate.label == "ArkTraceSnapshot"
        and candidate.args == "console-ready"
        and tonumber(candidate.ark_clients or 0) >= 1
    end) ~= nil
  end)

  tmux({ "send-keys", "-t", nvim_pane, "Escape", ":ArkTraceClearInput", "Enter" })
  tmux({ "send-keys", "-l", "-t", nvim_pane, "fake_sig(" })

  ark_test.wait_for("signature help after typed open paren", 15000, function()
    tmux({ "send-keys", "-t", nvim_pane, "F9" })
    return latest_matching(function(candidate)
      return candidate.label == "ArkTraceKeySnapshot"
        and candidate.line == "fake_sig("
        and has_signature_float(candidate)
    end) ~= nil
  end)

  tmux({ "send-keys", "-l", "-t", nvim_pane, "m" })

  local blink_show = nil
  ark_test.wait_for("completion menu after typed argument prefix", 15000, function()
    tmux({ "send-keys", "-t", nvim_pane, "F9" })
    blink_show = latest_matching(function(candidate)
      return candidate.line == "fake_sig(m" and has_completion_menu(candidate)
    end)
    return blink_show ~= nil
  end)

  if not has_signature_float(blink_show) then
    ark_test.fail("signature help disappeared after key-driven completion appeared: " .. vim.inspect(blink_show))
  end
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
