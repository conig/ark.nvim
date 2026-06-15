vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_line_numbers")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'console saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

vim.g.ark_console_terminal_ui = true

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
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end

local winid = vim.fn.bufwinid(bufnr)
if type(winid) ~= "number" or winid <= 0 then
  ark_test.fail("console buffer is not visible")
end
vim.api.nvim_set_current_win(winid)

local function wait_for_window_state(label, opts)
  ark_test.wait_for(label, 5000, function()
    local concealcursor = vim.wo[winid].concealcursor or ""
    return vim.wo[winid].number == opts.number
      and vim.wo[winid].relativenumber == opts.relativenumber
      and vim.wo[winid].conceallevel == opts.conceallevel
      and concealcursor:find("i", 1, true) == nil
  end)
end

local function wait_for_mode(label, predicate)
  ark_test.wait_for(label, 5000, function()
    local mode = vim.api.nvim_get_mode().mode
    return type(mode) == "string" and predicate(mode)
  end)
end

wait_for_window_state("terminal console normal mode shows line numbers and output prefixes", {
  number = true,
  relativenumber = true,
  conceallevel = 0,
})

vim.api.nvim_exec_autocmds("InsertEnter", { buffer = bufnr })
wait_for_window_state("terminal console insert mode hides line numbers and prior output prefixes", {
  number = false,
  relativenumber = false,
  conceallevel = 2,
})

vim.api.nvim_exec_autocmds("InsertLeave", { buffer = bufnr })
wait_for_window_state("terminal console normal mode restores line numbers and output prefixes", {
  number = true,
  relativenumber = true,
  conceallevel = 0,
})

-- Visual selection in the terminal transcript should keep line numbers available.
vim.api.nvim_feedkeys("v", "nx", false)
wait_for_mode("terminal console enters visual mode", function(mode)
  return mode == "v" or mode == "V" or mode == "\22"
end)
wait_for_window_state("terminal console visual mode shows line numbers and output prefixes", {
  number = true,
  relativenumber = true,
  conceallevel = 0,
})

vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
wait_for_mode("terminal console exits visual mode", function(mode)
  return mode:sub(1, 1) == "n"
end)
wait_for_window_state("terminal console normal mode keeps line numbers and output prefixes", {
  number = true,
  relativenumber = true,
  conceallevel = 0,
})

vim.print({
  nvim_console_line_numbers = "ok",
})

stop_watchdog()
