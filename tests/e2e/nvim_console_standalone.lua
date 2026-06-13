vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_standalone")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-standalone")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

vim.g.ark_console_standalone = true

local initial_wins = #vim.api.nvim_list_wins()
local initial_bufnr = vim.api.nvim_get_current_buf()

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start standalone nvim console: " .. tostring(err))
end

if bufnr ~= initial_bufnr then
  ark_test.fail("standalone console should reuse the current buffer")
end
if #vim.api.nvim_list_wins() ~= initial_wins then
  ark_test.fail("standalone console should not create an extra split")
end
if vim.api.nvim_buf_get_name(bufnr):find("input%.R", 1, false) then
  ark_test.fail("standalone console should not expose the old input.R buffer name")
end
if not vim.api.nvim_buf_get_name(bufnr):find("ark%-console://", 1, false)
  or not vim.api.nvim_buf_get_name(bufnr):find("console%.R", 1, false)
then
  ark_test.fail("standalone console should use a console.R virtual URI: " .. vim.api.nvim_buf_get_name(bufnr))
end
if vim.bo[bufnr].buflisted ~= false
  or vim.bo[bufnr].filetype ~= "r"
  or vim.bo[bufnr].syntax ~= "r"
  or vim.o.showtabline ~= 0
  or vim.o.laststatus ~= 0
  or vim.o.cmdheight ~= 0
  or vim.o.statusline ~= " "
  or vim.wo[0].number ~= false
  or vim.wo[0].relativenumber ~= false
  or vim.wo[0].signcolumn ~= "no"
  or vim.wo[0].conceallevel ~= 2
then
  ark_test.fail("standalone console should use terminal-like REPL UI: " .. vim.inspect({
    buflisted = vim.bo[bufnr].buflisted,
    filetype = vim.bo[bufnr].filetype,
    syntax = vim.bo[bufnr].syntax,
    showtabline = vim.o.showtabline,
    laststatus = vim.o.laststatus,
    cmdheight = vim.o.cmdheight,
    statusline = vim.o.statusline,
    number = vim.wo[0].number,
    relativenumber = vim.wo[0].relativenumber,
    signcolumn = vim.wo[0].signcolumn,
    conceallevel = vim.wo[0].conceallevel,
  }))
end

ark_test.wait_for("standalone fake prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

stop_watchdog()
