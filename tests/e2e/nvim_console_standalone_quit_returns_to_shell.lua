vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_standalone_quit_returns_to_shell")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-quit")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'saw: %s\\n' \"$line\"",
  "  if [ \"$line\" = 'quit()' ]; then",
  "    exit 0",
  "  fi",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local child_script = vim.fs.normalize(run_tmpdir .. "/child.lua")
vim.fn.writefile({
  "vim.opt.rtp:prepend(vim.fn.getcwd())",
  "vim.g.ark_console_standalone = true",
  "vim.g.ark_console_terminal_ui = true",
  "local ark = require('ark')",
  "ark.setup({",
  "  auto_start_pane = false,",
  "  auto_start_lsp = false,",
  "  terminal = {",
  "    launcher = " .. vim.inspect(launcher) .. ",",
  "    startup_status_dir = " .. vim.inspect(vim.fs.normalize(run_tmpdir .. "/status")) .. ",",
  "    session_pkg_path = " .. vim.inspect(vim.fs.normalize(run_tmpdir .. "/arkbridge")) .. ",",
  "  },",
  "})",
  "local bufnr = assert(ark.console())",
  "local sent = false",
  "local timer = vim.uv.new_timer()",
  "timer:start(100, 100, vim.schedule_wrap(function()",
  "  local status = require('ark.console').status(bufnr)",
  "  if type(status) == 'table' and status.running == true and not sent then",
  "    sent = true",
  "    require('ark.console').send_text(bufnr, 'quit()')",
  "  end",
  "end))",
  "vim.defer_fn(function()",
  "  vim.api.nvim_err_writeln('child nvim-console did not exit after quit()')",
  "  vim.cmd('cquit 3')",
  "end, 10000)",
}, child_script)

local stderr = {}
local child_job = vim.fn.jobstart({
  vim.v.progpath,
  "--headless",
  "-n",
  "-u",
  "NONE",
  "-i",
  "NONE",
  "-c",
  "luafile " .. child_script,
}, {
  cwd = vim.fn.getcwd(),
  stderr_buffered = true,
  on_stderr = function(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        stderr[#stderr + 1] = line
      end
    end
  end,
})

if type(child_job) ~= "number" or child_job <= 0 then
  stop_watchdog()
  ark_test.fail("failed to start child standalone nvim-console")
end

local exit_code = nil
local exited = vim.wait(6000, function()
  local status = vim.fn.jobwait({ child_job }, 0)[1]
  if status ~= -1 then
    exit_code = status
    return true
  end
  return false
end, 100, false)

if not exited then
  pcall(vim.fn.jobstop, child_job)
  stop_watchdog()
  ark_test.fail("standalone nvim-console did not return control to its launcher after quit()")
end

local stderr_text = table.concat(stderr, "\n")
if stderr_text:find("child nvim%-console did not exit after quit%(%)") then
  stop_watchdog()
  ark_test.fail("standalone nvim-console reached its quit() fail-safe: exit=" .. tostring(exit_code))
end

stop_watchdog()
