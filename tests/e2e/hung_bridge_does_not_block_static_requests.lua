vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(20000, "hung_bridge_does_not_block_static_requests")
local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local port_file = run_tmpdir .. "/port"
local request_log = run_tmpdir .. "/requests.log"
local server_script = run_tmpdir .. "/hung_bridge.py"
local status_file = run_tmpdir .. "/status.json"
local test_file = run_tmpdir .. "/hung_bridge.R"

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
  "def hang(client):",
  "    with client:",
  "        payload = b''",
  "        while not payload.endswith(b'\\n'):",
  "            chunk = client.recv(4096)",
  "            if not chunk:",
  "                break",
  "            payload += chunk",
  "        with open(request_log, 'a', encoding='utf-8') as stream:",
  "            stream.write(payload.decode('utf-8', errors='replace'))",
  "        time.sleep(5)",
  "",
  "while True:",
  "    client, _ = server.accept()",
  "    threading.Thread(target=hang, args=(client,), daemon=True).start()",
}, server_script)

local server_job = vim.fn.jobstart({ "python3", server_script, port_file, request_log })
if server_job <= 0 then
  ark_test.fail("failed to start disposable hung bridge")
end

local client_id = nil
local completion_request_id = nil
local ok, err = pcall(function()
  ark_test.wait_for("hung bridge port", 5000, function()
    return vim.fn.filereadable(port_file) == 1
  end)
  local port = tonumber(vim.fn.readfile(port_file)[1])
  if not port then
    ark_test.fail("hung bridge did not publish a port")
  end

  vim.fn.writefile({
    vim.json.encode({
      status = "ready",
      repl_ready = true,
      port = port,
      auth_token = "hung-bridge-token",
    }),
  }, status_file)
  vim.fn.writefile({ "x <- 1", "slow_bridge_object$" }, test_file)
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
      ARK_SESSION_ID = "hung-bridge-session",
      ARK_SESSION_TMUX_SOCKET = "/tmp/hung-bridge.sock",
      ARK_SESSION_TMUX_SESSION = "hung-bridge",
      ARK_SESSION_TMUX_PANE = "%1",
      ARK_SESSION_TIMEOUT_MS = "1000",
    },
  }, { bufnr = 0 })

  ark_test.wait_for("detached LSP client", 5000, function()
    local client = client_id and vim.lsp.get_client_by_id(client_id) or nil
    return client and client.initialized and not client:is_stopped()
  end)

  local client = assert(vim.lsp.get_client_by_id(client_id))
  local completion_params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 1, character = 19 },
  }
  local sent
  sent, completion_request_id = client:request(
    "textDocument/completion",
    completion_params,
    function() end,
    0
  )
  if not sent then
    ark_test.fail("failed to send hung bridge completion request")
  end

  ark_test.wait_for("hung completion to enter bridge transport", 5000, function()
    if vim.fn.filereadable(request_log) ~= 1 then
      return false
    end
    return table.concat(vim.fn.readfile(request_log), "\n"):find("slow_bridge_object", 1, true) ~= nil
  end)

  local started = vim.uv.hrtime()
  local response, request_err = client:request_sync("textDocument/documentSymbol", {
    textDocument = vim.lsp.util.make_text_document_params(0),
  }, 400, 0)
  local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

  if request_err or not response or response.err or response.error then
    ark_test.fail(
      string.format(
        "hung bridge delayed unrelated static symbols for %.1f ms: %s",
        elapsed_ms,
        vim.inspect(request_err or (response and (response.err or response.error)))
      )
    )
  end
  if elapsed_ms > 300 then
    ark_test.fail(string.format("static symbols took %.1f ms while bridge was hung", elapsed_ms))
  end
  if type(response.result) ~= "table" or #response.result == 0 then
    ark_test.fail("static document symbols returned no result while bridge was hung")
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
