vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("syntax on")

vim.api.nvim_set_hl(0, "Normal", { fg = "#c1b692", bg = "#0c0102" })
package.loaded.base46 = {
  get_theme_tb = function(name)
    if name == "base_30" then
      return {
        darker_black = "#030001",
        black = "#0c0102",
        black2 = "#140405",
        one_bg = "#201415",
        one_bg2 = "#2c2021",
        one_bg3 = "#423031",
        white = "#c1b692",
        lighter_white = "#d7d6d7",
        green = "#e0e183",
        grey_fg = "#867656",
        red = "#98171c",
        baby_pink = "#c7312b",
        yellow = "#e8a516",
        cyan = "#dab55b",
        orange = "#cb6a23",
      }
    end
    if name == "base_16" then
      return {
        base00 = "#0c0102",
        base05 = "#c1b692",
        base08 = "#98171c",
        base0A = "#e8a516",
        base0B = "#e0e183",
        base0C = "#dab55b",
      }
    end
    return {}
  end,
}

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_highlights")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-highlights")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '*** startup banner\\n'",
  "printf '\\033[31mARK_RED_OUTPUT\\033[0m\\n'",
  "printf '\\033[91mARK_BRIGHT_RED_OUTPUT\\033[0m\\n'",
  "printf 'Error: object not found\\n'",
  "printf '\\033[1mError: help\\033[0m\\n'",
  "printf 'Warning message:\\n'",
  "printf 'Loading required package: stats\\n'",
  "printf 'Learn more about the underlying theory at https://ggplot2-book.org/\\n'",
  "printf '[1] 42\\n'",
  "printf '> '",
  "while IFS= read -r line; do",
  "  if [ \"$line\" = 'message(\"hello\")' ]; then",
  "    printf 'hello\\n'",
  "  else",
  "    printf 'saw: %s\\n' \"$line\"",
  "  fi",
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
    and find_line(lines, "#> ARK_BRIGHT_RED_OUTPUT") ~= nil
    and find_line(lines, "#> Error: object not found") ~= nil
    and find_line(lines, "#> Error: help") ~= nil
    and find_line(lines, "#> Warning message:") ~= nil
    and find_line(lines, "#> Loading required package: stats") ~= nil
    and find_line(lines, "#> Learn more about the underlying theory") ~= nil
    and find_line(lines, "#> [1] 42") ~= nil
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
if output_group ~= "ArkConsoleOutput" or output_translated == "Error" then
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
local ansi_red_group = nil
for _, mark in ipairs(ansi_marks) do
  local details = mark[4]
  local group = type(details) == "table" and details.hl_group or nil
  if type(group) == "string" and group:find("^ArkConsoleAnsi") then
    saw_ansi_highlight = true
    ansi_red_group = group
    break
  end
end
if not saw_ansi_highlight then
  ark_test.fail("ANSI-styled output should preserve SGR styling as a highlight range: " .. vim.inspect({
    line = ansi_line,
    marks = ansi_marks,
  }))
end
local ansi_red_hl = vim.api.nvim_get_hl(0, { name = ansi_red_group, link = false })
if ansi_red_hl.fg ~= tonumber("98171c", 16) then
  ark_test.fail("ANSI red should use Base46 red: " .. vim.inspect({
    group = ansi_red_group,
    hl = ansi_red_hl,
  }))
end

local bright_ansi_index, bright_ansi_line = find_line(lines, "#> ARK_BRIGHT_RED_OUTPUT")
if not bright_ansi_index then
  ark_test.fail("expected bright ANSI-styled console output line: " .. vim.inspect(lines))
end
local bright_ansi_col = (bright_ansi_line:find("ARK_BRIGHT_RED_OUTPUT", 1, true) or 1) - 1
local bright_ansi_marks = vim.api.nvim_buf_get_extmarks(bufnr, ansi_ns, { bright_ansi_index - 1, bright_ansi_col }, {
  bright_ansi_index - 1,
  bright_ansi_col + #"ARK_BRIGHT_RED_OUTPUT",
}, { details = true })
local bright_red_group = nil
for _, mark in ipairs(bright_ansi_marks) do
  local details = mark[4]
  local group = type(details) == "table" and details.hl_group or nil
  if type(group) == "string" and group:find("^ArkConsoleAnsi") then
    bright_red_group = group
    break
  end
end
local bright_red_hl = bright_red_group and vim.api.nvim_get_hl(0, { name = bright_red_group, link = false }) or {}
if bright_red_hl.fg ~= tonumber("c7312b", 16) then
  ark_test.fail("ANSI bright red should use Base46 bright red slot: " .. vim.inspect({
    group = bright_red_group,
    hl = bright_red_hl,
    marks = bright_ansi_marks,
  }))
end

local function has_span_group(row, text, expected_group)
  local col = (text:find("%S") or 1) - 1
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ansi_ns, { row - 1, col }, {
    row - 1,
    #text,
  }, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if type(details) == "table" and details.hl_group == expected_group then
      return true, marks
    end
  end
  return false, marks
end

local semantic_cases = {
  { needle = "#> Error: object not found", group = "ArkConsoleOutputError" },
  { needle = "#> Error: help", group = "ArkConsoleOutputError" },
  { needle = "#> Warning message:", group = "ArkConsoleOutputWarning" },
  { needle = "#> Loading required package: stats", group = "ArkConsoleOutputMessage" },
  { needle = "#> Learn more about the underlying theory", group = "ArkConsoleOutputMessage" },
  { needle = "#> [1] 42", group = "ArkConsoleOutputValue" },
}
for _, case in ipairs(semantic_cases) do
  local row, text = find_line(lines, case.needle)
  if not row then
    ark_test.fail("expected semantic console output line: " .. vim.inspect(case))
  end
  local ok_group, marks = has_span_group(row, text, case.group)
  if not ok_group then
    ark_test.fail("semantic console output used wrong group: " .. vim.inspect({
      case = case,
      text = text,
      marks = marks,
    }))
  end
end

local error_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputError", link = false })
if error_hl.fg ~= tonumber("c7312b", 16) then
  ark_test.fail("main Ark console should define semantic error output as readable Diablo red: " .. vim.inspect(error_hl))
end

local message_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputMessage", link = false })
if message_hl.fg ~= tonumber("dab55b", 16) then
  ark_test.fail("main Ark console should define semantic message output as readable Diablo message color: " .. vim.inspect(message_hl))
end

local send_ok, send_err = require("ark.console").send_text(bufnr, 'message("hello")')
if not send_ok then
  ark_test.fail("failed to send message() input: " .. tostring(send_err))
end

ark_test.wait_for("message() output", 10000, function()
  lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return find_line(lines, "#> hello") ~= nil
end)

local hello_row, hello_text = find_line(lines, "#> hello")
local ok_hello_group, hello_marks = has_span_group(hello_row, hello_text, "ArkConsoleOutputMessage")
if not ok_hello_group then
  ark_test.fail("message() output should use semantic message highlight: " .. vim.inspect({
    text = hello_text,
    marks = hello_marks,
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
if input_group ~= "rOpError" then
  ark_test.fail("editable input should still use R syntax highlighting: " .. vim.inspect({
    group = input_group,
    translated = input_translated,
    stack = syntax_stack_at(status.input_start + 1, 1),
  }))
end

stop_watchdog()
