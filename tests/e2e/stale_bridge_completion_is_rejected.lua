vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(20000, "stale_bridge_completion_is_rejected")
local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local port_file = run_tmpdir .. "/port"
local request_log = run_tmpdir .. "/requests.log"
local server_script = run_tmpdir .. "/delayed_bridge.py"
local status_file = run_tmpdir .. "/status.json"
local test_file = run_tmpdir .. "/stale_completion.R"

vim.fn.writefile({
  "import json",
  "import socket",
  "import sys",
  "import threading",
  "import time",
  "",
  "port_file, request_log = sys.argv[1:]",
  "server = socket.socket()",
  "server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)",
  "server.bind(('127.0.0.1', 0))",
  "server.listen()",
  "with open(port_file, 'w', encoding='utf-8') as stream:",
  "    stream.write(str(server.getsockname()[1]))",
  "",
  "def serve(client):",
  "    with client:",
  "        payload = b''",
  "        while not payload.endswith(b'\\n'):",
  "            chunk = client.recv(4096)",
  "            if not chunk:",
  "                break",
  "            payload += chunk",
  "        request = json.loads(payload.decode('utf-8'))",
  "        with open(request_log, 'a', encoding='utf-8') as stream:",
  "            stream.write(json.dumps(request) + '\\n')",
  "        if request.get('command') == 'bootstrap':",
  "            response = {'status': 'ok', 'search_path_symbols': ['library'], 'library_paths': ['/tmp']} ",
  "        elif 'slow_stale_object' in request.get('expr', ''):",
  "            time.sleep(0.6)",
  "            response = {'members': [{'name_raw': 'STALE_MEMBER', 'type': 'numeric'}]} ",
  "        else:",
  "            response = {'members': []}",
  "        client.sendall(json.dumps(response).encode('utf-8'))",
  "",
  "while True:",
  "    client, _ = server.accept()",
  "    threading.Thread(target=serve, args=(client,), daemon=True).start()",
}, server_script)

local server_job = vim.fn.jobstart({ "python3", server_script, port_file, request_log })
if server_job <= 0 then
  ark_test.fail("failed to start disposable delayed bridge")
end

local client_id = nil
local completion_request_id = nil
local ok, err = pcall(function()
  ark_test.wait_for("delayed bridge port", 5000, function()
    return vim.fn.filereadable(port_file) == 1
  end)
  local port = tonumber(vim.fn.readfile(port_file)[1])
  if not port then
    ark_test.fail("delayed bridge did not publish a port")
  end

  local manifest = assert(require("ark.release").manifest())
  vim.fn.writefile({
    vim.json.encode({
      status = "ready",
      repl_ready = true,
      port = port,
      auth_token = "stale-bridge-token",
      product_version = manifest.product_version,
      bridge_schema = manifest.compatibility.bridge_schema,
    }),
  }, status_file)
  vim.fn.writefile({ "slow_stale_object$" }, test_file)
  vim.cmd("edit " .. vim.fn.fnameescape(test_file))
  vim.cmd("setfiletype r")

  local lsp_cmd = require("ark.config").defaults().lsp.cmd
  ark_test.assert_fresh_detached_lsp_binary(lsp_cmd[1])
  client_id = vim.lsp.start({
    name = "ark_lsp",
    cmd = lsp_cmd,
    root_dir = run_tmpdir,
    cmd_env = {
      ARK_SESSION_KIND = "ark",
      ARK_SESSION_STATUS_FILE = status_file,
      ARK_SESSION_BACKEND = "tmux",
      ARK_SESSION_ID = "stale-bridge-session",
      ARK_SESSION_TMUX_SOCKET = "/tmp/stale-bridge.sock",
      ARK_SESSION_TMUX_SESSION = "stale-bridge",
      ARK_SESSION_TMUX_PANE = "%1",
      ARK_SESSION_TIMEOUT_MS = "1000",
    },
  }, { bufnr = 0 })

  ark_test.wait_for("detached LSP client", 5000, function()
    local client = client_id and vim.lsp.get_client_by_id(client_id) or nil
    return client and client.initialized and not client:is_stopped()
  end)

  local client = assert(vim.lsp.get_client_by_id(client_id))
  local completion_done = false
  local completion_err = nil
  local completion_result = nil
  local sent
  sent, completion_request_id = client:request("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 0, character = 18 },
  }, function(request_err, result)
    completion_err = request_err
    completion_result = result
    completion_done = true
  end, 0)
  if not sent then
    ark_test.fail("failed to send delayed completion request")
  end

  ark_test.wait_for("delayed completion to enter bridge", 5000, function()
    if vim.fn.filereadable(request_log) ~= 1 then
      return false
    end
    return table.concat(vim.fn.readfile(request_log), "\n"):find("slow_stale_object", 1, true) ~= nil
  end)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "newer_document <- 1" })
  local symbols, symbols_err = client:request_sync("textDocument/documentSymbol", {
    textDocument = vim.lsp.util.make_text_document_params(0),
  }, 1000, 0)
  if symbols_err or not symbols then
    ark_test.fail("failed to synchronize the newer document: " .. vim.inspect(symbols_err))
  end

  ark_test.wait_for("delayed completion response", 3000, function()
    return completion_done
  end)

  local items = ark_test.completion_items(completion_result)
  if not completion_err and ark_test.find_item(items, "STALE_MEMBER") then
    ark_test.fail("completion from the old document version was delivered after didChange")
  end
end)

if client_id then
  local client = vim.lsp.get_client_by_id(client_id)
  if client and completion_request_id then
    pcall(client.cancel_request, client, completion_request_id)
  end
  pcall(vim.lsp.stop_client, client_id, true)
end
pcall(vim.fn.jobstop, server_job)
vim.fn.delete(run_tmpdir, "rf")
stop_watchdog()

if not ok then
  error(err, 0)
end
