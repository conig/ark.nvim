local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("startup_keyword_completion"))
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/startup_keyword_state")
local socket_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/startup-keyword.nvim.sock")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/startup-keyword.R")
local probe_path = vim.fs.normalize(repo_root .. "/tests/e2e/tui_startup_keyword_completion_probe.lua")
local stop_watchdog = ark_test.start_watchdog(90000, "full_config_startup_keyword_completion_recovery_tui")
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

local function contains(values, label)
  for _, value in ipairs(values or {}) do
    if value == label then
      return true
    end
  end
  return false
end

local function has_typed_prefix(state)
  return type(state) == "table"
    and (state.line == "lm(data = mt" or state.line == "lm(data = mt)")
end

local function child_state()
  if vim.fn.filereadable(socket_path) ~= 1 then
    return nil
  end

  local output = vim.fn.system({
    "nvim",
    "--server",
    socket_path,
    "--remote-expr",
    "v:lua.__ark_startup_keyword_completion_state()",
  })
  if vim.v.shell_error ~= 0 or output == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(socket_path)

  local nvim_cmd = table.concat({
    "XDG_STATE_HOME=" .. vim.fn.shellescape(state_home),
    "XDG_DATA_HOME=" .. vim.fn.shellescape(vim.env.XDG_DATA_HOME or vim.fn.stdpath("data")),
    "ARK_REPO_ROOT=" .. vim.fn.shellescape(repo_root),
    "ARK_TMUX_SOCKET=" .. vim.fn.shellescape(vim.env.ARK_TMUX_SOCKET or ""),
    "env -u ARK_TMUX_ANCHOR_PANE -u ARK_TMUX_SESSION",
    "nvim",
    "--listen",
    vim.fn.shellescape(socket_path),
    "-n",
    "-u",
    vim.fn.shellescape(init_path),
    vim.fn.shellescape(buffer_path),
    "-c",
    "'set shadafile=NONE'",
    "-c",
    "'luafile " .. probe_path .. "'",
  }, " ")

  local pane_id = vim.trim(tmux({ "new-session", "-d", "-P", "-F", "#{pane_id}", "-s", session_name, nvim_cmd }))
  if pane_id == "" then
    ark_test.fail("failed to capture child Neovim pane id")
  end

  ark_test.wait_for("child Neovim RPC socket", 10000, function()
    return vim.fn.filereadable(socket_path) == 1
  end)

  -- Reproduce the user-speed cold-start path: type before the LSP has a
  -- chance to answer keyword completions, then require startup recovery to
  -- reopen Blink when Ark finishes hydrating.
  vim.wait(20, function()
    return false
  end, 10, false)
  tmux({ "send-keys", "-t", pane_id, "i" })
  tmux({ "send-keys", "-t", pane_id, "-l", "lm(data = mt" })

  ark_test.wait_for("child startup keyword probe", 15000, function()
    local state = child_state()
    return type(state) == "table" and state.probe_loaded == true
  end)

  local pre_type_state = nil
  local typed_ok = vim.wait(10000, function()
    local state = child_state()
    pre_type_state = pre_type_state or state
    return has_typed_prefix(state)
  end, 100, false)
  if not typed_ok then
    local final_state = child_state()
    local screen = tmux({ "capture-pane", "-p", "-t", pane_id }, true)
    ark_test.fail("failed to type startup keyword prefix in child TUI: " .. vim.inspect({
      pre_type_state = pre_type_state,
      final_state = final_state,
      screen = screen,
    }))
  end

  local ready_state = nil
  ark_test.wait_for("direct LSP mtcars completion after startup", 30000, function()
    local state = child_state()
    if type(state) ~= "table" then
      return false
    end
    local status = type(state.status) == "table" and state.status or {}
    if status.bridge_ready
      and status.repl_ready
      and status.lsp_available
      and status.main_buffer_unlocked
      and contains(state.lsp_labels, "mtcars")
    then
      ready_state = state
      return true
    end
    return false
  end)

  local menu_state = nil
  local menu_ok = vim.wait(10000, function()
    local state = child_state()
    if type(state) == "table" and state.blink_visible and contains(state.blink_labels, "mtcars") then
      menu_state = state
      return true
    end
    return false
  end, 100, false)

  if not menu_ok then
    local final_state = child_state()
    local screen = tmux({ "capture-pane", "-p", "-t", pane_id }, true)
    ark_test.fail("startup keyword completion did not reopen Blink after Ark became ready: " .. vim.inspect({
      ready_state = ready_state,
      final_state = final_state,
      screen = screen,
    }))
  end

  vim.print({
    ready_state = ready_state,
    pre_type_state = pre_type_state,
    menu_state = menu_state,
  })
end, debug.traceback)

cleanup()
stop_watchdog()

if not ok then
  error(err, 0)
end
