vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("syntax on")

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_highlights")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-highlights")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '*** startup banner\\n'",
  "printf '\\033[31mARK_RED_OUTPUT\\033[0m\\n'",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'saw: %s\\n' \"$line\"",
  "  printf '> '",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

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

local function syntax_group_at(row, col)
  local id = vim.fn.synID(row, col, 1)
  return vim.fn.synIDattr(id, "name"), vim.fn.synIDattr(vim.fn.synIDtrans(id), "name")
end

local function syntax_stack_at(row, col)
  local names = {}
  for _, id in ipairs(vim.fn.synstack(row, col)) do
    names[#names + 1] = {
      name = vim.fn.synIDattr(id, "name"),
      translated = vim.fn.synIDattr(vim.fn.synIDtrans(id), "name"),
    }
  end
  return names
end

local function find_line(lines, needle)
  for index, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return index, line
    end
  end
  return nil, nil
end

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start highlight console: " .. tostring(err))
end

ark_test.wait_for("highlight fake prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return type(status) == "table"
    and status.running == true
    and status.prompt_state == "top-level"
    and find_line(lines, "#> *** startup banner") ~= nil
    and find_line(lines, "#> ARK_RED_OUTPUT") ~= nil
end)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local output_index, output_line = find_line(lines, "#> *** startup banner")
if not output_index then
  ark_test.fail("expected highlighted console output line: " .. vim.inspect(lines))
end

-- Regression: the concealed "#> " prefix must not let R syntax parse "***" as
-- a bare operator error in transcript output.
local output_star_col = output_line:find("***", 1, true)
local output_group, output_translated = syntax_group_at(output_index, output_star_col)
if output_group ~= "ArkConsoleOutput" or output_translated ~= "Normal" then
  ark_test.fail("console output should use neutral ArkConsoleOutput highlight: " .. vim.inspect({
    line = output_line,
    group = output_group,
    translated = output_translated,
    stack = syntax_stack_at(output_index, output_star_col),
  }))
end

local prefix_group = syntax_group_at(output_index, 1)
if prefix_group ~= "ArkConsoleOutputPrefix" then
  ark_test.fail("console output prefix should keep its dedicated conceal group: " .. vim.inspect({
    line = output_line,
    group = prefix_group,
    stack = syntax_stack_at(output_index, 1),
  }))
end

local ansi_index, ansi_line = find_line(lines, "#> ARK_RED_OUTPUT")
if not ansi_index then
  ark_test.fail("expected ANSI-styled console output line: " .. vim.inspect(lines))
end
if ansi_line:find("\27", 1, true) then
  ark_test.fail("console output should not expose raw ANSI escape bytes: " .. vim.inspect(ansi_line))
end

local ansi_ns = vim.api.nvim_get_namespaces().ArkConsoleAnsi
if type(ansi_ns) ~= "number" then
  ark_test.fail("ANSI-styled console output should create ArkConsoleAnsi highlight extmarks")
end

local ansi_col = (ansi_line:find("ARK_RED_OUTPUT", 1, true) or 1) - 1
local ansi_marks = vim.api.nvim_buf_get_extmarks(bufnr, ansi_ns, { ansi_index - 1, ansi_col }, {
  ansi_index - 1,
  ansi_col + #"ARK_RED_OUTPUT",
}, { details = true })
local saw_ansi_highlight = false
for _, mark in ipairs(ansi_marks) do
  local details = mark[4]
  local group = type(details) == "table" and details.hl_group or nil
  if type(group) == "string" and group:find("^ArkConsoleAnsi") then
    saw_ansi_highlight = true
    break
  end
end
if not saw_ansi_highlight then
  ark_test.fail("ANSI-styled output should preserve SGR styling as a highlight range: " .. vim.inspect({
    line = ansi_line,
    marks = ansi_marks,
  }))
end

local namespaces = vim.api.nvim_get_namespaces()
local prompt_ns = namespaces.ArkConsole
local prompt_marks = type(prompt_ns) == "number"
    and vim.api.nvim_buf_get_extmarks(bufnr, prompt_ns, 0, -1, { details = true })
  or {}
local saw_prompt_highlight = false
for _, mark in ipairs(prompt_marks) do
  local details = mark[4]
  local chunk = type(details) == "table" and type(details.virt_text) == "table" and details.virt_text[1] or nil
  if type(chunk) == "table" and chunk[2] == "ArkConsolePrompt" then
    saw_prompt_highlight = true
    break
  end
end
if not saw_prompt_highlight then
  ark_test.fail("active prompt should render with ArkConsolePrompt: " .. vim.inspect(prompt_marks))
end

local status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "*** input" })
local input_group, input_translated = syntax_group_at(status.input_start + 1, 1)
if input_group ~= "rOpError" or input_translated ~= "Error" then
  ark_test.fail("editable input should still use R syntax highlighting: " .. vim.inspect({
    group = input_group,
    translated = input_translated,
    stack = syntax_stack_at(status.input_start + 1, 1),
  }))
end

stop_watchdog()
