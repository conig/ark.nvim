vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_signature_help")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local blink_menu_visible = false
package.preload["blink.cmp"] = function()
  return {
    is_visible = function()
      return blink_menu_visible
    end,
    is_menu_visible = function()
      return blink_menu_visible
    end,
  }
end
package.preload["blink.cmp.completion.list"] = function()
  return {
    undo_preview = function() end,
  }
end
package.preload["blink.cmp.completion.trigger"] = function()
  return {
    hide = function()
      blink_menu_visible = false
    end,
  }
end
package.preload["blink.cmp.completion.windows.menu"] = function()
  return {
    close = function()
      blink_menu_visible = false
    end,
  }
end

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
  "    if method == 'textDocument/signatureHelp':",
  "        log({'event': 'signatureHelp', 'params': message.get('params')})",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'signatures': [{'label': 'fake_sig(x, y)', 'parameters': [{'label': [9, 10]}, {'label': [12, 13]}], 'activeParameter': 0}], 'activeSignature': 0, 'activeParameter': 0}})",
  "        continue",
  "    if request_id is None:",
  "        continue",
  "    if method == 'initialize':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'capabilities': {'textDocumentSync': 1, 'signatureHelpProvider': {'triggerCharacters': ['(', ',', '=']}}}})",
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
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

vim.api.nvim_win_set_buf(0, bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fake_sig(" })
vim.api.nvim_win_set_cursor(0, { 1, #"fake_sig(" })
vim.api.nvim_exec_autocmds("TextChangedI", {
  buffer = bufnr,
})

local function signature_help_request_count()
  if vim.fn.filereadable(seen_log) ~= 1 then
    return 0
  end

  local count = 0
  for _, line in ipairs(vim.fn.readfile(seen_log)) do
    if line:find('"event": "signatureHelp"', 1, true) then
      count = count + 1
    end
  end
  return count
end

ark_test.wait_for("console signature help request", 10000, function()
  return signature_help_request_count() == 1
end)

local function signature_help_float_visible()
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(winid)
    if config.relative ~= "" then
      local float_bufnr = vim.api.nvim_win_get_buf(winid)
      local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
      if table.concat(lines, "\n"):find("fake_sig", 1, true) then
        return true
      end
    end
  end
  return false
end

ark_test.wait_for("console signature help float", 10000, function()
  return signature_help_float_visible()
end)

blink_menu_visible = true
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fake_sig(x =" })
vim.api.nvim_win_set_cursor(0, { 1, #"fake_sig(x =" })
vim.api.nvim_exec_autocmds("TextChangedI", {
  buffer = bufnr,
})

-- Regression: when a completion menu is visible at a signature trigger, the
-- console should prefer signature help, close completion, and still request
-- the LSP signature. Suppressing the request makes signature help feel flaky
-- compared with a normal R buffer.
ark_test.wait_for("console signature help request wins over visible Blink menu", 10000, function()
  return signature_help_request_count() == 2
end)

ark_test.wait_for("console hides Blink before showing trigger signature help", 4000, function()
  return blink_menu_visible == false
end)

ark_test.wait_for("console signature help float remains visible after Blink menu closes", 10000, function()
  return signature_help_float_visible()
end)

blink_menu_visible = true
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "fake_sig(x = mt" })
vim.api.nvim_win_set_cursor(0, { 1, #"fake_sig(x = mt" })
vim.api.nvim_exec_autocmds("TextChangedI", {
  buffer = bufnr,
})

-- Regression: after signature help is already visible, a keyword completion
-- refresh inside the same call must not close the signature float. The normal
-- Ark/Blink collision handler owns any menu repositioning or hiding.
vim.wait(300)
if not signature_help_float_visible() then
  ark_test.fail("console signature help disappeared when Blink completion appeared")
end

if signature_help_request_count() ~= 2 then
  ark_test.fail("Blink-visible console signature trigger should request signature help: " .. vim.inspect({
    count = signature_help_request_count(),
    log = vim.fn.filereadable(seen_log) == 1 and vim.fn.readfile(seen_log) or {},
  }))
end

stop_watchdog()
