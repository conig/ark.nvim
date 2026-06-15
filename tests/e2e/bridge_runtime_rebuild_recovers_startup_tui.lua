local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repo_root = vim.fs.normalize(vim.fn.getcwd())
local session_name = ark_test.register_tmux_session(ark_test.tmux_session_name("bridge_rebuild_recovers"))
local state_home = vim.fs.normalize(ark_test.run_tmpdir() .. "/bridge-rebuild-state")
local socket_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/bridge-rebuild.nvim.sock")
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/bridge-rebuild.R")
local probe_path = vim.fs.normalize(repo_root .. "/tests/e2e/tui_startup_keyword_completion_probe.lua")
local stop_watchdog = ark_test.start_watchdog(120000, "bridge_runtime_rebuild_recovers_startup_tui")

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

local function corrupt_installed_bridge_runtime()
  local data_home = vim.env.XDG_DATA_HOME or vim.fn.stdpath("data")
  local lib_path = vim.fs.normalize(data_home .. "/nvim/ark/r-lib")
  local installed = lib_path .. "/arkbridge"
  local stamp = lib_path .. "/.arkbridge-install.json"

  vim.fn.mkdir(installed, "p")
  vim.fn.delete(installed, "rf")
  vim.fn.mkdir(installed, "p")
  vim.fn.writefile({
    vim.json.encode({
      source_mtime = 1,
    }),
  }, stamp)
end

local ok, err = xpcall(function()
  cleanup()
  vim.fn.delete(socket_path)
  corrupt_installed_bridge_runtime()

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
    vim.fn.shellescape(repo_root .. "/tests/e2e/init.lua"),
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

  ark_test.wait_for("child startup probe", 15000, function()
    local state = child_state()
    return type(state) == "table" and state.probe_loaded == true
  end)

  ark_test.wait_for("child Ark recovered after bridge rebuild", 60000, function()
    local state = child_state()
    local status = type(state) == "table" and type(state.status) == "table" and state.status or {}
    return status.bridge_ready
      and status.repl_ready
      and status.lsp_available
      and status.main_buffer_unlocked
      and tonumber(status.console_scope_count or 0) > 0
  end)

  tmux({ "send-keys", "-t", pane_id, "i" })
  tmux({ "send-keys", "-t", pane_id, "-l", "lm(data = mt" })

  local lsp_state = nil
  ark_test.wait_for("lm(data = mt recovered LSP completion", 15000, function()
    local state = child_state()
    if type(state) == "table" and contains(state.lsp_labels, "mtcars") then
      lsp_state = state
      return true
    end
    return false
  end)

  local menu_state = nil
  ark_test.wait_for("lm(data = mt recovered Blink completion", 15000, function()
    local state = child_state()
    if type(state) == "table" and state.blink_visible and contains(state.blink_labels, "mtcars") then
      menu_state = state
      return true
    end
    return false
  end)

  vim.print({
    lsp_state = lsp_state,
    menu_state = menu_state,
  })
end, debug.traceback)

cleanup()
stop_watchdog()

if not ok then
  error(err, 0)
end
