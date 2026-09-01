vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(15000, "nvim_console_stale_rpc_status")

local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_stale_rpc_status")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")
local stale_socket = vim.fs.normalize(run_tmpdir .. "/stale-console.sock")
local session = {
  tmux_socket = vim.fs.normalize(run_tmpdir .. "/tmux.sock"),
  tmux_session = "ark-stale-console",
  tmux_pane = "%24",
}

vim.fn.mkdir(status_dir, "p")

-- Keep the test at the user-facing send boundary while isolating it from a
-- real tmux server. These are the two tmux lookups used to validate and
-- refresh the already-known managed pane.
package.loaded["ark.tmux_transport"] = {
  run = function(args)
    local format = args[#args]
    if format == "#{pane_id}" then
      return session.tmux_pane, nil
    end
    if format == "#{socket_path}\n#{session_name}" then
      return session.tmux_socket .. "\n" .. session.tmux_session, nil
    end
    return nil, "unexpected tmux call: " .. vim.inspect(args)
  end,
  shell_join = function(args)
    return table.concat(args, " ")
  end,
  start = function()
    return nil, "unexpected tmux start"
  end,
  strip_ansi = function(value)
    return value
  end,
  trim = vim.trim,
}

_G.__ark_nvim_state = {
  active_index = 1,
  managed = true,
  next_tab_id = 2,
  tabs = {
    {
      id = 1,
      managed = true,
      pane_id = session.tmux_pane,
      session = vim.deepcopy(session),
      visible = true,
    },
  },
}

local tmux = require("ark.tmux")
local session_id = tmux.session_id(session)
local status_path = vim.fs.normalize(status_dir .. "/" .. session_id .. ".json")

-- Reproduce the observed restart race: a status file still advertises the
-- previous nvim-console RPC address after that Neovim process has exited.
-- The old fallback shells out to `nvim --server`, leaking E247 and "Send
-- expression failed" into the user-visible error instead of treating the
-- console endpoint as temporarily unavailable.
local config = {
  console_frontend = "nvim-console",
  startup_status_dir = status_dir,
}

local function publish_stale_status(pid)
  vim.fn.writefile({
    vim.json.encode({
      nvim_console = true,
      nvim_console_pid = pid,
      nvim_console_rpc_socket = stale_socket,
      nvim_console_running = true,
      nvim_console_session_id = session_id,
    }),
  }, status_path)
end

-- Even if the advertised PID still exists, the listener can disappear
-- between status validation and connect. Ark must not shell out to the same
-- refused endpoint and expose the raw remote-expression failure.
publish_stale_status(vim.fn.getpid())
local ok, err = tmux.send_text(config, "mean(mtcars$mpg)")
if ok ~= nil then
  error("refused nvim-console endpoint unexpectedly accepted the send", 0)
end
if err ~= "managed nvim-console RPC endpoint is not accepting connections" then
  error("refused nvim-console endpoint leaked its raw socket error: " .. tostring(err), 0)
end

-- Once the publisher PID has exited, the stale status must not be selected at
-- all while a replacement console is starting.
publish_stale_status(2147483647)
ok, err = tmux.send_text(config, "mean(mtcars$mpg)")

stop_watchdog()

if ok ~= nil then
  error("stale nvim-console status unexpectedly accepted the send", 0)
end
if err ~= "managed nvim-console RPC endpoint is not ready" then
  error("stale nvim-console status leaked its refused socket error: " .. tostring(err), 0)
end
