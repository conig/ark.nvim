vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_lsp_attach")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local fake_lsp = vim.fs.normalize(run_tmpdir .. "/fake-lsp")
local seen_log = vim.fs.normalize(run_tmpdir .. "/seen.jsonl")
vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import json",
  "import sys",
  "",
  "seen_log = " .. vim.json.encode(seen_log),
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
  "def log(payload):",
  "    with open(seen_log, 'a', encoding='utf-8') as f:",
  "        f.write(json.dumps(payload) + '\\n')",
  "",
  "while True:",
  "    message = read_message()",
  "    if message is None:",
  "        break",
  "    method = message.get('method')",
  "    request_id = message.get('id')",
  "    if method == 'textDocument/didOpen':",
  "        log({'event': 'didOpen', 'uri': message['params']['textDocument']['uri'], 'text': message['params']['textDocument']['text']})",
  "        continue",
  "    if method == 'textDocument/completion':",
  "        log({'event': 'completion', 'uri': message['params']['textDocument']['uri']})",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'isIncomplete': False, 'items': [{'label': 'console_completion'}]}})",
  "        continue",
  "    if request_id is None:",
  "        continue",
  "    if method == 'initialize':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'capabilities': {'completionProvider': {'triggerCharacters': ['$']}}}})",
  "    else:",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': None})",
}, fake_lsp)
vim.fn.setfperm(fake_lsp, "rwxr-xr-x")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = true,
  lsp = {
    cmd = { fake_lsp },
  },
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end

ark_test.wait_for("console ark_lsp client", 10000, function()
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })
  return clients[1] and clients[1].initialized == true
end)

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mtcars$" })
vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_win_set_cursor(0, { 1, 6 })

local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
local response, request_err = client:request_sync("textDocument/completion", {
  textDocument = {
    uri = vim.uri_from_bufnr(bufnr),
  },
  position = {
    line = 0,
    character = 6,
  },
  context = {
    triggerKind = 2,
    triggerCharacter = "$",
  },
}, 10000, bufnr)
if request_err then
  ark_test.fail("console completion request failed: " .. request_err)
end
local items = ark_test.completion_items(response and response.result)
if not ark_test.find_item(items, "console_completion") then
  ark_test.fail("console completion missing fake LSP item: " .. vim.inspect(items))
end

ark_test.wait_for("console didOpen URI", 10000, function()
  if vim.fn.filereadable(seen_log) ~= 1 then
    return false
  end
  local text = table.concat(vim.fn.readfile(seen_log), "\n")
  return text:find("ark%-console://", 1, false) ~= nil
end)

stop_watchdog()
