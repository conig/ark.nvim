vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_long_session_rpc")

local run_tmpdir = vim.fs.normalize(ark_test.run_tmpdir() .. "/nvim_console_long_session_rpc")
local status_dir = vim.fs.normalize(run_tmpdir .. "/status")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")

vim.fn.mkdir(status_dir, "p")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

-- A long tmux session name pushes the pane-specific suffix beyond Linux's
-- 107-byte Unix socket pathname limit. The two managed panes must still get
-- independent RPC listeners instead of aliasing to the same kernel address.
local encoded_stem = "%2Ftmp%2Ftmux-user%2Fdefault__"
  .. "a_very_long_managed_project_session_name_"
while #(status_dir .. "/" .. encoded_stem .. "%2540.sock") <= 120 do
  encoded_stem = encoded_stem .. "extended_"
end

local first_session_id = encoded_stem .. "%2540"
local second_session_id = encoded_stem .. "%2562"
local first_socket = vim.fs.normalize(status_dir .. "/" .. first_session_id .. ".sock")
local second_socket = vim.fs.normalize(status_dir .. "/" .. second_session_id .. ".sock")

if first_socket:sub(1, 107) ~= second_socket:sub(1, 107) then
  ark_test.fail("long-session fixture does not reproduce the shared Unix socket prefix")
end

local first_server = vim.fn.serverstart(first_socket)
local console_bufnr
local ok, err = xpcall(function()
  vim.env.TMUX = nil
  vim.env.TMUX_PANE = nil
  vim.env.ARK_TMUX_SOCKET = nil
  vim.env.ARK_SESSION_ID = second_session_id

  local ark = require("ark")
  ark.setup({
    auto_start_lsp = false,
    auto_start_pane = false,
    terminal = {
      launcher = launcher,
      session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
      startup_status_dir = status_dir,
    },
  })

  local start_err
  console_bufnr, start_err = ark.console()
  if not console_bufnr then
    ark_test.fail("failed to start long-session console: " .. tostring(start_err))
  end

  local console_status = require("ark.console").status(console_bufnr)
  local published = require("ark.session_runtime").read_status_file(console_status.status_path)
  if type(published) ~= "table" or type(published.nvim_console_rpc_socket) ~= "string" then
    ark_test.fail("long-session console did not publish a ready RPC endpoint: " .. vim.inspect({
      console = console_status,
      published = published,
      transcript = vim.api.nvim_buf_get_lines(console_bufnr, 0, -1, false),
    }))
  end

  local server_list = vim.fn.serverlist()
  if not vim.tbl_contains(server_list, published.nvim_console_rpc_socket) then
    ark_test.fail("published long-session RPC endpoint is not listening: " .. vim.inspect({
      published = published.nvim_console_rpc_socket,
      servers = server_list,
    }))
  end
end, debug.traceback)

if console_bufnr and vim.api.nvim_buf_is_valid(console_bufnr) then
  pcall(require("ark.console").stop, console_bufnr)
  pcall(vim.api.nvim_buf_delete, console_bufnr, { force = true })
end
pcall(vim.fn.serverstop, first_server)
stop_watchdog()

if not ok then
  error(err, 0)
end
