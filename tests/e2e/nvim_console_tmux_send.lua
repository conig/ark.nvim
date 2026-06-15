local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("nvim_console_send"))
local trace_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_send_trace.log")
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_send_state")
local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_send")
local fake_lsp = vim.fs.normalize(run_tmpdir .. "/fake-lsp")
local fake_slime_rtp = vim.fs.normalize(run_tmpdir .. "/fake-slime")
local fake_slime_tmux = vim.fs.normalize(fake_slime_rtp .. "/autoload/slime/targets/tmux.vim")
local fake_r = vim.fs.normalize(run_tmpdir .. "/fake-r")
local fake_r_log = vim.fs.normalize(run_tmpdir .. "/fake-r.log")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")
local stop_watchdog = ark_test.start_watchdog(90000, "nvim_console_tmux_send")
local init_path = vim.env.ARK_TEST_NVIM_INIT

if type(init_path) ~= "string" or init_path == "" or init_path == "NONE" then
  init_path = vim.fs.normalize(repo_root .. "/tests/e2e/init.lua")
end

vim.fn.mkdir(run_tmpdir, "p")
vim.fn.mkdir(status_dir, "p")
vim.fn.mkdir(vim.fs.dirname(fake_slime_tmux), "p")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf '%s\\n' \"$line\" >> " .. vim.fn.shellescape(fake_r_log),
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, fake_r)
vim.fn.setfperm(fake_r, "rwxr-xr-x")

vim.fn.writefile({
  "function! slime#targets#tmux#send(config, text) abort",
  "  let l:cmd = ['tmux']",
  "  if has_key(a:config, 'socket_name') && type(a:config.socket_name) == v:t_string && a:config.socket_name !=# ''",
  "    call extend(l:cmd, ['-S', a:config.socket_name])",
  "  endif",
  "  let l:buffer = 'ark-fake-slime-' . reltimefloat(reltime())",
  "  call system(l:cmd + ['set-buffer', '-b', l:buffer, a:text])",
  "  if v:shell_error != 0",
  "    return 0",
  "  endif",
  "  call system(l:cmd + ['paste-buffer', '-d', '-b', l:buffer, '-t', a:config.target_pane])",
  "  return v:shell_error == 0 ? 1 : 0",
  "endfunction",
}, fake_slime_tmux)

vim.fn.writefile({
  "#!/usr/bin/env python3",
  "import json",
  "import sys",
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
  "    request_id = message.get('id')",
  "    method = message.get('method')",
  "    if method == 'textDocument/didOpen' or method == 'textDocument/didChange':",
  "        continue",
  "    if request_id is None:",
  "        continue",
  "    if method == 'initialize':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'capabilities': {'textDocumentSync': 1, 'completionProvider': {'triggerCharacters': ['$', '(', ')']}}}})",
  "    elif method == 'textDocument/completion':",
  "        send({'jsonrpc': '2.0', 'id': request_id, 'result': {'isIncomplete': False, 'items': [{'label': 'managed_console_blink_item', 'kind': 6}, {'label': 'ggplot2', 'kind': 9}]}})",
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

local function status_files()
  return vim.fn.glob(status_dir .. "/*.json", false, true)
end

local function fake_r_log_lines()
  if vim.fn.filereadable(fake_r_log) ~= 1 then
    return {}
  end
  return vim.fn.readfile(fake_r_log)
end

local function fake_r_log_text()
  return table.concat(fake_r_log_lines(), "\n")
end

local function fake_r_log_contains_line(line)
  for _, logged in ipairs(fake_r_log_lines()) do
    if logged == line then
      return true
    end
  end
  return false
end

local function fake_r_log_has_ordered_lines(first, second)
  local saw_first = false
  for _, logged in ipairs(fake_r_log_lines()) do
    if logged == first then
      saw_first = true
    elseif saw_first and logged == second then
      return true
    end
  end
  return false
end

local function slime_send_payload(nvim_pane, label, lines)
  local payload_path = vim.fs.normalize(run_tmpdir .. "/" .. label .. ".R")
  vim.fn.writefile(lines, payload_path)
  local command = ":lua require('ark')._slime_override_send(vim.b.slime_config, table.concat(vim.fn.readfile("
    .. vim.fn.string(payload_path)
    .. "), '\\n') .. '\\n')"
  tmux({ "send-keys", "-t", nvim_pane, "Escape", command, "Enter" })
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
    "ARK_NVIM_CONSOLE_FRONTEND=nvim-console",
    "ARK_NVIM_CONSOLE_BIN=" .. vim.fn.shellescape(repo_root .. "/scripts/ark-console"),
    "ARK_TMUX_SOCKET=" .. vim.fn.shellescape(vim.env.ARK_TMUX_SOCKET or ""),
    "env -u ARK_TMUX_ANCHOR_PANE -u ARK_TMUX_SESSION",
    "nvim",
    "-n",
    "-u",
    vim.fn.shellescape(init_path),
    "-c",
    "'set rtp^=" .. fake_slime_rtp .. "'",
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

  tmux({ "send-keys", "-t", nvim_pane, "Escape", ":Ark pane start", "Enter" })

  local console_status = nil
  ark_test.wait_for("managed nvim-console status", 20000, function()
    for _, path in ipairs(status_files()) do
      local status = require("ark.session_runtime").read_status_file(path)
      if type(status) == "table"
        and status.nvim_console == true
        and type(status.nvim_console_rpc_socket) == "string"
        and status.nvim_console_rpc_socket ~= ""
      then
        console_status = status
        return true
      end
    end
    return false
  end)

  local panes_after_console_start = tmux({
    "list-panes",
    "-t",
    session_name,
    "-F",
    "#{pane_id}\t#{pane_active}\t#{pane_current_command}",
  })
  local console_pane = nil
  for line in panes_after_console_start:gmatch("[^\n]+") do
    local pane_id, active = line:match("^([^\t]+)\t([^\t]+)")
    if pane_id and pane_id ~= nvim_pane and active == "0" then
      console_pane = pane_id
      break
    end
  end
  if not console_pane then
    ark_test.fail("failed to identify managed nvim-console pane: " .. panes_after_console_start)
  end

  local rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to connect to managed nvim-console RPC socket for Blink probe")
  end
  local blink_ok, blink_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mtcars$" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    vim.wait(10000, function()
      return #(vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp", method = "textDocument/completion" }) or {}) >= 1
    end, 50, false)
    vim.cmd("startinsert")
    vim.wait(4000, function()
      return vim.fn.mode():sub(1, 1) == "i"
    end, 20, false)
    local ok_blink, blink = pcall(require, "blink.cmp")
    if not ok_blink then
      return {
        ok = false,
        reason = "blink.cmp unavailable",
        clients = #(vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" }) or {}),
        line = vim.api.nvim_get_current_line(),
        normal_windows = 0,
      }
    end
    local show_result = blink.show({ providers = { "lsp" } })
    vim.wait(5000, function()
      local ok_list, list = pcall(require, "blink.cmp.completion.list")
      return blink.is_visible() or (ok_list and type(list.items) == "table" and #list.items > 0)
    end, 50, false)
    local ok_list, list = pcall(require, "blink.cmp.completion.list")
    local item_labels = {}
    if ok_list and type(list.items) == "table" then
      for _, item in ipairs(list.items) do
        item_labels[#item_labels + 1] = item.label
      end
    end
    local normal_windows = 0
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(winid).relative == "" then
        normal_windows = normal_windows + 1
      end
    end
    return {
      ok = blink.is_visible(),
      show_result = show_result,
      item_labels = item_labels,
      clients = #(vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" }) or {}),
      completion_clients = #(vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp", method = "textDocument/completion" }) or {}),
      line = vim.api.nvim_get_current_line(),
      mode = vim.fn.mode(),
      normal_windows = normal_windows,
      buflisted = vim.bo[bufnr].buflisted,
      filetype = vim.bo[bufnr].filetype,
      syntax = vim.bo[bufnr].syntax,
      showtabline = vim.o.showtabline,
      laststatus = vim.o.laststatus,
      cmdheight = vim.o.cmdheight,
      winbar = vim.wo[0].winbar,
      statusline = vim.wo[0].statusline,
      number = vim.wo[0].number,
      relativenumber = vim.wo[0].relativenumber,
      signcolumn = vim.wo[0].signcolumn,
      conceallevel = vim.wo[0].conceallevel,
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not blink_ok or type(blink_result) ~= "table" or blink_result.ok ~= true then
    ark_test.fail("managed nvim-console Blink probe failed: " .. vim.inspect(blink_result))
  end
  if tonumber(blink_result.clients or 0) < 1 then
    ark_test.fail("managed nvim-console Blink probe did not have ark_lsp attached: " .. vim.inspect(blink_result))
  end
  if tonumber(blink_result.normal_windows or 0) ~= 1 then
    ark_test.fail("managed nvim-console should not create an internal horizontal split: " .. vim.inspect(blink_result))
  end
  if blink_result.buflisted ~= false
    or blink_result.filetype ~= "r"
    or blink_result.syntax ~= "r"
    or tonumber(blink_result.showtabline) ~= 0
    or tonumber(blink_result.laststatus) ~= 0
    or tonumber(blink_result.cmdheight) ~= 0
    or blink_result.winbar ~= ""
    or blink_result.statusline ~= " "
    or blink_result.number ~= false
    or blink_result.relativenumber ~= false
    or blink_result.signcolumn ~= "no"
    or tonumber(blink_result.conceallevel) ~= 2
  then
    ark_test.fail("managed nvim-console should use terminal-like REPL UI: " .. vim.inspect(blink_result))
  end

  -- Regression coverage for the real vim-slime/nvim-slimetree style path.
  -- The fake vim-slime tmux target performs the same raw pane paste that
  -- exposed this bug. For the nvim-console frontend, Ark's slime override must
  -- route the text through the console RPC send path instead: no completion
  -- menu should appear after a complete call, and multiline R code must reach
  -- the backend as separate lines.
  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for raw paste setup")
  end
  local raw_paste_setup_ok, raw_paste_setup = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local bufnr = vim.api.nvim_get_current_buf()
    local status = require("ark.console").status(bufnr)
    local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
    if ok_trigger and type(trigger.hide) == "function" then
      pcall(trigger.hide)
    end
    vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { status.input_start + 1, 0 })
    vim.cmd("startinsert")
    return {
      ok = true,
      line = vim.api.nvim_get_current_line(),
      mode = vim.fn.mode(),
      input_start = status.input_start,
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not raw_paste_setup_ok or type(raw_paste_setup) ~= "table" or raw_paste_setup.ok ~= true then
    ark_test.fail("managed nvim-console raw paste setup failed: " .. vim.inspect(raw_paste_setup))
  end

  slime_send_payload(nvim_pane, "raw-library", { "library(ggplot2)" })
  ark_test.wait_for("raw tmux paste delivered library call", 10000, function()
    return fake_r_log_contains_line("library(ggplot2)")
  end)

  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for raw paste assertion")
  end
  local raw_library_ok, raw_library_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    vim.wait(1000, function()
      local ok_blink, blink = pcall(require, "blink.cmp")
      return ok_blink and blink.is_visible()
    end, 20, false)
    local ok_blink, blink = pcall(require, "blink.cmp")
    local ok_list, list = pcall(require, "blink.cmp.completion.list")
    local labels = {}
    if ok_list and type(list.items) == "table" then
      for _, item in ipairs(list.items) do
        labels[#labels + 1] = item.label
      end
    end
    local status = require("ark.console").status(0)
    return {
      visible = ok_blink and blink.is_visible() or false,
      labels = labels,
      line = vim.api.nvim_get_current_line(),
      mode = vim.fn.mode(),
      current_input = type(status) == "table"
          and table.concat(vim.api.nvim_buf_get_lines(0, status.input_start, -1, false), "\n")
        or nil,
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not raw_library_ok or type(raw_library_result) ~= "table" then
    ark_test.fail("managed nvim-console raw library paste assertion failed: " .. vim.inspect(raw_library_result))
  end

  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for multiline raw paste setup")
  end
  local raw_multiline_setup_ok, raw_multiline_setup = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local status = require("ark.console").status(0)
    local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
    if ok_trigger and type(trigger.hide) == "function" then
      pcall(trigger.hide)
    end
    vim.api.nvim_buf_set_lines(0, status.input_start, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { status.input_start + 1, 0 })
    vim.cmd("startinsert")
    return {
      ok = true,
      line = vim.api.nvim_get_current_line(),
      mode = vim.fn.mode(),
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not raw_multiline_setup_ok or type(raw_multiline_setup) ~= "table" or raw_multiline_setup.ok ~= true then
    ark_test.fail("managed nvim-console raw multiline setup failed: " .. vim.inspect(raw_multiline_setup))
  end

  local raw_pipe_first = "lm(mpg ~ wt, data = mtcars) |>"
  local raw_pipe_second = "    summary()"
  slime_send_payload(nvim_pane, "raw-pipe", { raw_pipe_first, raw_pipe_second })
  vim.wait(1000, function()
    return fake_r_log_has_ordered_lines(raw_pipe_first, raw_pipe_second)
      or fake_r_log_contains_line(raw_pipe_first .. raw_pipe_second:gsub("^%s*", ""))
      or fake_r_log_contains_line(raw_pipe_first .. raw_pipe_second)
  end, 20, false)

  local raw_paste_failures = {}
  if raw_library_result.visible == true then
    raw_paste_failures[#raw_paste_failures + 1] = "library(ggplot2) raw paste opened Blink: "
      .. vim.inspect(raw_library_result)
  end
  if not fake_r_log_has_ordered_lines(raw_pipe_first, raw_pipe_second) then
    raw_paste_failures[#raw_paste_failures + 1] = "multiline raw paste did not reach R as separate lines: "
      .. vim.inspect(fake_r_log_lines())
  end
  if #raw_paste_failures > 0 then
    ark_test.fail(table.concat(raw_paste_failures, "\n"))
  end

  local direct_output = vim.fn.system({
    "nvim",
    "--server",
    console_status.nvim_console_rpc_socket,
    "--remote-expr",
    "v:lua.__ark_console_rpc_send('direct_socket_send()')",
  })
  if vim.v.shell_error ~= 0 or vim.trim(direct_output) ~= "ok" then
    ark_test.fail("direct console socket send failed: " .. direct_output)
  end

  ark_test.wait_for("managed nvim-console direct socket send", 20000, function()
    return fake_r_log_text():find("direct_socket_send%(%)") ~= nil
  end)

  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for send state probe")
  end
  local state_prepare_ok, state_prepare_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local function stop_insert()
      if vim.fn.mode():sub(1, 1) == "i" then
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
        vim.wait(4000, function()
          return vim.fn.mode() == "n"
        end, 20, false)
      end
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local found = vim.wait(10000, function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return table.concat(lines, "\n"):find("#> console saw: direct_socket_send%(%)") ~= nil
    end, 50, false)
    if not found then
      return {
        ok = false,
        reason = "console transcript did not contain direct_socket_send() output",
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      }
    end

    stop_insert()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local row = nil
    for index, line in ipairs(lines) do
      if line:find("direct_socket_send()", 1, true) then
        row = index
        break
      end
    end
    if row == nil then
      return {
        ok = false,
        reason = "failed to locate protected direct_socket_send() row",
        lines = lines,
      }
    end

    vim.api.nvim_win_set_cursor(0, { row, 0 })
    return {
      ok = true,
      cursor = vim.api.nvim_win_get_cursor(0),
      input_start = require("ark.console").status(bufnr).input_start,
      mode = vim.fn.mode(),
      row = row,
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not state_prepare_ok or type(state_prepare_result) ~= "table" or state_prepare_result.ok ~= true then
    ark_test.fail("managed nvim-console send state setup failed: " .. vim.inspect(state_prepare_result))
  end

  local state_send_output = vim.fn.system({
    "nvim",
    "--server",
    console_status.nvim_console_rpc_socket,
    "--remote-expr",
    "v:lua.__ark_console_rpc_send('send_after_normal_cursor()')",
  })
  if vim.v.shell_error ~= 0 or vim.trim(state_send_output) ~= "ok" then
    ark_test.fail("direct console socket send from normal cursor failed: " .. state_send_output)
  end

  ark_test.wait_for("managed nvim-console R process received normal-cursor send", 20000, function()
    return fake_r_log_text():find("send_after_normal_cursor%(%)") ~= nil
  end)

  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for send state assertion")
  end
  local state_after_ok, state_after_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local bufnr = vim.api.nvim_get_current_buf()
    vim.wait(4000, function()
      local status = require("ark.console").status(bufnr)
      local cursor = vim.api.nvim_win_get_cursor(0)
      return type(status) == "table" and cursor[1] >= status.input_start + 1
    end, 20, false)

    local status = require("ark.console").status(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local mode = vim.fn.mode()
    return {
      ok = type(status) == "table" and cursor[1] >= status.input_start + 1,
      cursor = cursor,
      input_start = type(status) == "table" and status.input_start or nil,
      mode = mode,
      line = vim.api.nvim_get_current_line(),
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not state_after_ok or type(state_after_result) ~= "table" or state_after_result.ok ~= true then
    ark_test.fail("managed nvim-console send should restore input cursor state: " .. vim.inspect(state_after_result))
  end

  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for normal-mode completion probe")
  end
  local normal_completion_ok, normal_completion_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local function stop_insert()
      if vim.fn.mode():sub(1, 1) == "i" then
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
        vim.wait(4000, function()
          return vim.fn.mode() == "n"
        end, 20, false)
      end
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local status = require("ark.console").status(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "mtcars$" })
    vim.api.nvim_win_set_cursor(0, { status.input_start + 1, 7 })
    stop_insert()
    local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
    if ok_trigger and type(trigger.hide) == "function" then
      pcall(trigger.hide)
    end
    local ok_blink, blink = pcall(require, "blink.cmp")
    if not ok_blink then
      return {
        ok = false,
        reason = "blink.cmp unavailable",
      }
    end
    local show_result = blink.show({ providers = { "lsp" } })
    vim.wait(500, function()
      return blink.is_visible()
    end, 20, false)
    local visible = blink.is_visible()
    return {
      ok = visible == false,
      visible = visible,
      show_result = show_result,
      mode = vim.fn.mode(),
      cursor = vim.api.nvim_win_get_cursor(0),
      input_start = require("ark.console").status(bufnr).input_start,
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not normal_completion_ok
    or type(normal_completion_result) ~= "table"
    or normal_completion_result.ok ~= true
  then
    ark_test.fail("managed nvim-console should suppress normal-mode completions: " .. vim.inspect(normal_completion_result))
  end

  rpc_chan = vim.fn.sockconnect("pipe", console_status.nvim_console_rpc_socket, { rpc = true })
  if type(rpc_chan) ~= "number" or rpc_chan <= 0 then
    ark_test.fail("failed to reconnect to managed nvim-console RPC socket for edit protection probe")
  end
  local edit_ok, edit_result = pcall(vim.rpcrequest, rpc_chan, "nvim_exec_lua", [[
    local function stop_insert()
      if vim.fn.mode():sub(1, 1) == "i" then
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
        vim.wait(4000, function()
          return vim.fn.mode() == "n"
        end, 20, false)
      end
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local found = vim.wait(10000, function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return table.concat(lines, "\n"):find("#> console saw: direct_socket_send%(%)") ~= nil
    end, 50, false)
    if not found then
      return {
        ok = false,
        reason = "console transcript did not contain direct_socket_send() output",
        lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      }
    end

    stop_insert()
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local row = nil
    for index, line in ipairs(before) do
      if line:find("direct_socket_send()", 1, true) then
        row = index
        break
      end
    end
    if row == nil then
      return {
        ok = false,
        reason = "failed to locate protected direct_socket_send() row",
        lines = before,
      }
    end

    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_feedkeys(vim.keycode("A_MUTATE<Esc>"), "xt", false)
    vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      return vim.inspect(lines) == vim.inspect(before)
    end, 20, false)

    local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return {
      ok = vim.inspect(after) == vim.inspect(before),
      before = before,
      after = after,
      row = row,
    }
  ]], {})
  pcall(vim.fn.chanclose, rpc_chan)
  if not edit_ok or type(edit_result) ~= "table" or edit_result.ok ~= true then
    ark_test.fail("managed nvim-console protected edit probe failed: " .. vim.inspect(edit_result))
  end

  tmux({
    "send-keys",
    "-t",
    nvim_pane,
    "Escape",
    ":ArkTraceSend rpc_tmux_send()",
    "Enter",
  })

  local send_result = nil
  ark_test.wait_for("main editor Ark send result", 20000, function()
    send_result = latest_matching(function(candidate)
      return candidate.label == "ArkTraceSend" and candidate.args == "rpc_tmux_send()"
    end)
    return send_result ~= nil
  end)
  if send_result.sent ~= true then
    ark_test.fail("main editor Ark send failed: " .. vim.inspect(send_result))
  end

  ark_test.wait_for("managed nvim-console R process received direct send", 20000, function()
    return fake_r_log_text():find("rpc_tmux_send%(%)") ~= nil
  end)

  if type(console_status) ~= "table" then
    ark_test.fail("missing console status after send")
  end
end, debug.traceback)

cleanup()
stop_watchdog()
if not ok then
  error(err, 0)
end
