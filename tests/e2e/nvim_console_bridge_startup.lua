local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_bridge_startup")
end

local function ensure_bridge_runtime_current()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, err = bridge.ensure_current_runtime(config, {
    on_build_complete = function(result)
      completed = result
    end,
    user_initiated = true,
  })
  if ok then
    return
  end

  if type(err) ~= "table" or err.kind ~= "build_pending" then
    ark_test.fail("failed to prepare pane-side arkbridge runtime: " .. vim.inspect(err))
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    ark_test.fail("timed out waiting for pane-side arkbridge runtime install: " .. vim.inspect(completed or err))
  end

  local retry_ok, retry_err = bridge.ensure_current_runtime(config, {})
  if not retry_ok then
    ark_test.fail("pane-side arkbridge runtime was not current after install: " .. vim.inspect(retry_err))
  end
end

ensure_bridge_runtime_current()

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local lsp_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-lsp")
ark_test.assert_fresh_detached_lsp_binary(lsp_bin)

local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("nvim_console_bridge"))
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_bridge")
local trace_path = vim.fs.normalize(run_tmpdir .. "/trace.log")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")
local state_home = vim.fs.normalize(run_tmpdir .. "/state")
local session_lib = vim.fs.normalize((vim.fn.stdpath("data") or "/tmp") .. "/ark/r-lib")
local stop_watchdog = ark_test.start_watchdog(90000, "nvim_console_bridge_startup")
local init_path = vim.env.ARK_TEST_NVIM_INIT

if type(init_path) ~= "string" or init_path == "" or init_path == "NONE" then
  init_path = vim.fs.normalize(repo_root .. "/tests/e2e/init.lua")
end

vim.fn.mkdir(run_tmpdir, "p")
vim.fn.mkdir(status_dir, "p")

local function elapsed_ms(start_ns)
  return math.floor((vim.uv.hrtime() - start_ns) / 1e6)
end

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

local function status_files()
  return vim.fn.glob(status_dir .. "/*.json", false, true)
end

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(trace_path)

  local nvim_cmd = table.concat({
    "XDG_DATA_HOME=" .. vim.fn.shellescape(vim.env.XDG_DATA_HOME or ""),
    "XDG_STATE_HOME=" .. vim.fn.shellescape(state_home),
    "ARK_TUI_TRACE_LOG=" .. vim.fn.shellescape(trace_path),
    "ARK_REPO_ROOT=" .. vim.fn.shellescape(repo_root),
    "ARK_NVIM_LSP_BIN=" .. vim.fn.shellescape(lsp_bin),
    "ARK_NVIM_LAUNCHER=" .. vim.fn.shellescape(repo_root .. "/scripts/ark-r-launcher.sh"),
    "ARK_NVIM_SESSION_LIB=" .. vim.fn.shellescape(session_lib),
    "ARK_STATUS_DIR=" .. vim.fn.shellescape(status_dir),
    "ARK_NVIM_CONSOLE_FRONTEND=nvim-console",
    "ARK_NVIM_CONSOLE_BIN=" .. vim.fn.shellescape(vim.env.ARK_TEST_NVIM_CONSOLE_BIN or (repo_root .. "/scripts/ark-console")),
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

  local start_ns = vim.uv.hrtime()
  tmux({ "send-keys", "-t", nvim_pane, "Escape", ":Ark pane start", "Enter" })

  local console_status = nil
  local status_ready_ms = nil
  ark_test.wait_for("managed nvim-console bridge status", 30000, function()
    for _, path in ipairs(status_files()) do
      local status = require("ark.session_runtime").read_status_file(path)
      if type(status) == "table"
        and status.status == "ready"
        and status.repl_ready == true
        and tonumber(status.port) ~= nil
        and type(status.auth_token) == "string"
        and status.auth_token ~= ""
        and status.nvim_console == true
        and type(status.nvim_console_rpc_socket) == "string"
        and status.nvim_console_rpc_socket ~= ""
      then
        console_status = status
        status_ready_ms = elapsed_ms(start_ns)
        return true
      end
    end
    return false
  end)

  local rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to connect to managed nvim-console RPC socket")
  end

  local child_ok, child_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local start_ns = vim.uv.hrtime()
    local marks = {}

    local function elapsed_ms()
      return math.floor((vim.uv.hrtime() - start_ns) / 1e6)
    end

    local function mark(name)
      if marks[name] == nil then
        marks[name] = elapsed_ms()
      end
    end

    local function current_client()
      return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
    end

    local function current_status()
      local ok_ark, ark = pcall(require, "ark")
      if not ok_ark then
        return nil
      end
      return ark.status({ include_lsp = true })
    end

    local function wait_for(label, timeout_ms, predicate)
      local ok = vim.wait(timeout_ms, predicate, 20, false)
      if not ok then
        return nil, {
          ok = false,
          reason = "timed out waiting for " .. label,
          marks = marks,
          status = current_status(),
        }
      end
      mark(label)
      return true
    end

    local ok, err = wait_for("lsp_client", 15000, function()
      local client = current_client()
      return client ~= nil and client.initialized == true and not client:is_stopped()
    end)
    if not ok then
      return err
    end

    ok, err = wait_for("lsp_hydrated", 15000, function()
      local status = current_status()
      local lsp_status = status and status.lsp_status or nil
      local detached = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
      return type(status) == "table"
        and status.bridge_ready == true
        and status.repl_ready == true
        and type(lsp_status) == "table"
        and lsp_status.available == true
        and lsp_status.sessionBridgeConfigured == true
        and tonumber(lsp_status.consoleScopeCount or 0) > 0
        and tonumber(lsp_status.libraryPathCount or 0) > 0
        and type(detached) == "table"
        and type(detached.lastBootstrapSuccessMs) == "number"
    end)
    if not ok then
      return err
    end

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mtcars$" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    local client = current_client()
    local response, request_err = client:request_sync("textDocument/completion", {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = {
        line = 0,
        character = 7,
      },
      context = {
        triggerKind = 2,
        triggerCharacter = "$",
      },
    }, 10000, bufnr)
    if request_err or not response or response.error or response.err then
      return {
        ok = false,
        reason = "completion request failed",
        request_err = request_err,
        response = response,
        marks = marks,
        status = current_status(),
      }
    end

    local items = response.result and (response.result.items or response.result) or {}
    local labels = {}
    local found_mpg = false
    for _, item in ipairs(items) do
      labels[#labels + 1] = item.label
      if item.label == "mpg" then
        found_mpg = true
      end
    end
    if not found_mpg then
      return {
        ok = false,
        reason = "mtcars$ completion missing mpg",
        labels = labels,
        marks = marks,
        status = current_status(),
      }
    end
    mark("mtcars_completion")

    -- A successful async bootstrap should not leave a transient timeout warning
    -- in the visible standalone console messages.
    local messages = vim.fn.execute("messages")
    if messages:find("ark.nvim session bootstrap failed", 1, true) then
      return {
        ok = false,
        reason = "transient bootstrap warning was shown after successful hydration",
        messages = messages,
        labels = labels,
        marks = marks,
        status = current_status(),
      }
    end

    return {
      ok = true,
      marks = marks,
      labels = labels,
      messages = messages,
      status = current_status(),
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)

  if not child_ok or type(child_result) ~= "table" or child_result.ok ~= true then
    ark_test.fail("managed nvim-console bridge probe failed: " .. vim.inspect(child_result))
  end
  if tonumber(child_result.marks and child_result.marks.mtcars_completion or 99999) > 10000 then
    ark_test.fail("managed nvim-console LSP hydration/completion was too slow: " .. vim.inspect(child_result))
  end

  vim.print({
    status_ready_ms = status_ready_ms,
    child = child_result,
  })
end, debug.traceback)

cleanup()
stop_watchdog()

if not ok then
  error(err, 0)
end
