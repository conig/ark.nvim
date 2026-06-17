vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "ark_repl_theme_handoff")

vim.api.nvim_set_hl(0, "Normal", { fg = "#eeeeee", bg = "#111111" })
vim.api.nvim_set_hl(0, "Question", { fg = "#00ff99", bold = true })
vim.api.nvim_set_hl(0, "Comment", { fg = "#778899", italic = true })
vim.api.nvim_set_hl(0, "Function", { fg = "#abcdef" })
vim.api.nvim_set_hl(0, "String", { fg = "#fedcba" })
vim.g.terminal_color_1 = "#123456"
local base_30 = {
  darker_black = "#080808",
  black = "#111111",
  one_bg = "#1b1b1b",
  one_bg3 = "#333333",
  white = "#eeeeee",
  lighter_white = "#ddddcc",
  green = "#00ff99",
  grey_fg = "#778899",
  cyan = "#dab55b",
  red = "#98171c",
  blood = "#c7312b",
  yellow = "#e8a516",
  sun = "#f7d31a",
  orange = "#cb6a23",
}
package.loaded.base46 = {
  get_theme_tb = function(name)
    if name == "base_30" then
      return base_30
    end
    if name == "base_16" then
      return {}
    end
    return {}
  end,
}

local theme = require("ark.theme")
local path = vim.fs.normalize(vim.fn.tempname() .. ".json")
path = theme.write_snapshot_file(path)
if type(path) ~= "string" or vim.fn.filereadable(path) ~= 1 then
  ark_test.fail("theme snapshot file was not written: " .. vim.inspect(path))
end

local snapshot = theme.read(path)
if type(snapshot) ~= "table" then
  ark_test.fail("theme snapshot file was not readable: " .. vim.inspect(path))
end

if snapshot.console.prompt.fg ~= "#00ff99" then
  ark_test.fail("theme snapshot did not capture prompt highlight: " .. vim.inspect(snapshot.console.prompt))
end

if snapshot.console.output_prefix.fg ~= "#778899" then
  ark_test.fail("theme snapshot did not capture output prefix highlight: " .. vim.inspect(snapshot.console.output_prefix))
end

if snapshot.console.normal.bg ~= "#080808" then
  ark_test.fail("theme snapshot did not use darker Base46 REPL background: " .. vim.inspect(snapshot.console.normal))
end

if snapshot.console.signature.bg ~= "#1b1b1b" then
  ark_test.fail("theme snapshot did not use distinct signature-help background: " .. vim.inspect(snapshot.console.signature))
end

if snapshot.console.output_error.fg ~= "#c7312b" then
  ark_test.fail("theme snapshot did not use readable Diablo red for REPL errors: " .. vim.inspect(snapshot.console.output_error))
end

if snapshot.console.output_warning.fg ~= "#e8a516" then
  ark_test.fail("theme snapshot did not use Diablo yellow for REPL warnings: " .. vim.inspect(snapshot.console.output_warning))
end

if snapshot.console.output_message.fg ~= "#dab55b" then
  ark_test.fail("theme snapshot did not use Diablo message color: " .. vim.inspect(snapshot.console.output_message))
end

if snapshot.terminal.colors[2] ~= "#123456" then
  ark_test.fail("theme snapshot did not capture terminal color 1: " .. vim.inspect(snapshot.terminal.colors))
end

if snapshot.highlights.Function.fg ~= "#abcdef" then
  ark_test.fail("theme snapshot did not capture syntax highlights: " .. vim.inspect(snapshot.highlights.Function))
end

if snapshot.highlights.String.fg ~= "#fedcba" then
  ark_test.fail("theme snapshot did not capture string syntax highlights: " .. vim.inspect(snapshot.highlights.String))
end

base_30.green = "#44ccff"
theme.write_snapshot_file(path)
snapshot = theme.read(path)
if snapshot.console.prompt.fg ~= "#44ccff" then
  ark_test.fail("theme snapshot did not update in place: " .. vim.inspect(snapshot.console.prompt))
end

vim.api.nvim_set_hl(0, "ArkConsolePrompt", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "ArkConsoleOutputPrefix", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "Function", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "String", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "BlinkCmpMenu", { bg = "#ff0000" })
vim.api.nvim_set_hl(0, "ArkSignatureHelpNormal", { bg = "#ff0000" })
vim.api.nvim_set_hl(0, "ArkConsoleOutputError", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "ArkConsoleOutputWarning", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "ArkConsoleOutputMessage", { fg = "#ff0000" })
vim.api.nvim_set_hl(0, "ArkConsoleOutputValue", { fg = "#ff0000" })
vim.g.terminal_color_1 = "#ff0000"
vim.env.ARK_NVIM_REPL_THEME_FILE = path

if theme.apply_from_env() ~= true then
  ark_test.fail("theme snapshot was not applied from env")
end

local prompt_hl = vim.api.nvim_get_hl(0, { name = "ArkConsolePrompt", link = false })
if prompt_hl.fg ~= tonumber("44ccff", 16) then
  ark_test.fail("ArkConsolePrompt did not use snapshot palette: " .. vim.inspect(prompt_hl))
end

local normal_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleNormal", link = false })
if normal_hl.bg ~= tonumber("080808", 16) then
  ark_test.fail("ArkConsoleNormal did not use darker REPL background: " .. vim.inspect(normal_hl))
end

local function_hl = vim.api.nvim_get_hl(0, { name = "Function", link = false })
if function_hl.fg ~= tonumber("cb6a23", 16) then
  ark_test.fail("REPL Function highlight did not use safer Base46 orange: " .. vim.inspect(function_hl))
end

local r_function_hl = vim.api.nvim_get_hl(0, { name = "rFunction", link = false })
if r_function_hl.fg ~= tonumber("cb6a23", 16) then
  ark_test.fail("REPL rFunction highlight did not use safer Base46 orange: " .. vim.inspect(r_function_hl))
end

local function_call_hl = vim.api.nvim_get_hl(0, { name = "@function.call", link = false })
if function_call_hl.fg ~= tonumber("cb6a23", 16) then
  ark_test.fail("REPL @function.call highlight did not use safer Base46 orange: " .. vim.inspect(function_call_hl))
end

local string_hl = vim.api.nvim_get_hl(0, { name = "String", link = false })
if string_hl.fg ~= tonumber("fedcba", 16) then
  ark_test.fail("String syntax highlight did not use snapshot palette: " .. vim.inspect(string_hl))
end

local error_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputError", link = false })
if error_hl.fg ~= tonumber("c7312b", 16) or error_hl.bold ~= true then
  ark_test.fail("REPL error highlight did not use readable Diablo error palette: " .. vim.inspect(error_hl))
end

local warning_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputWarning", link = false })
if warning_hl.fg ~= tonumber("e8a516", 16) or warning_hl.bold ~= true then
  ark_test.fail("REPL warning highlight did not use Diablo warning palette: " .. vim.inspect(warning_hl))
end

local message_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputMessage", link = false })
if message_hl.fg ~= tonumber("dab55b", 16) then
  ark_test.fail("REPL message highlight did not use Diablo message palette: " .. vim.inspect(message_hl))
end

local value_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputValue", link = false })
if value_hl.fg ~= tonumber("ddddcc", 16) then
  ark_test.fail("REPL value highlight did not use Diablo value palette: " .. vim.inspect(value_hl))
end

local signature_hl = vim.api.nvim_get_hl(0, { name = "ArkSignatureHelpNormal", link = false })
if signature_hl.bg ~= tonumber("1b1b1b", 16) then
  ark_test.fail("signature help highlight did not use distinct snapshot background: " .. vim.inspect(signature_hl))
end

local blink_hl = vim.api.nvim_get_hl(0, { name = "BlinkCmpMenu", link = false })
if blink_hl.bg ~= tonumber("1b1b1b", 16) then
  ark_test.fail("Blink menu highlight did not use snapshot palette: " .. vim.inspect(blink_hl))
end

local prefix_hl = vim.api.nvim_get_hl(0, { name = "ArkConsoleOutputPrefix", link = false })
if prefix_hl.fg ~= tonumber("778899", 16) or prefix_hl.italic ~= true then
  ark_test.fail("ArkConsoleOutputPrefix did not use snapshot palette: " .. vim.inspect(prefix_hl))
end

if vim.g.terminal_color_1 ~= "#123456" then
  ark_test.fail("terminal color was not restored from snapshot: " .. vim.inspect(vim.g.terminal_color_1))
end

-- Regression coverage for the running REPL process: the parent editor updates
-- the handoff on NvChad/Base46 theme reload and the already-started receiver
-- applies it.
base_30.green = "#2255aa"
local live_path = theme.prepare_handoff()
if type(live_path) ~= "string" or vim.fn.filereadable(live_path) ~= 1 then
  ark_test.fail("theme handoff file was not prepared for live receiver test: " .. vim.inspect(live_path))
end

local run_tmpdir = ark_test.run_tmpdir()
vim.fn.mkdir(run_tmpdir, "p")
local child_script = vim.fs.normalize(run_tmpdir .. "/theme-receiver-child.lua")
local child_output = vim.fs.normalize(run_tmpdir .. "/theme-receiver-child.out")
vim.fn.writefile({
  "vim.opt.rtp:prepend(vim.fn.getcwd())",
  "local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. '/tests/e2e/ark_test.lua'))",
  "local stop_watchdog = ark_test.start_watchdog(20000, 'ark_repl_theme_receiver_child')",
  "local theme = require('ark.theme')",
  "local output = " .. vim.inspect(child_output),
  "local function prompt_color()",
  "  local hl = vim.api.nvim_get_hl(0, { name = 'ArkConsolePrompt', link = false })",
  "  if type(hl) ~= 'table' or type(hl.fg) ~= 'number' then",
  "    return nil",
  "  end",
  "  return string.format('#%06x', hl.fg)",
  "end",
  "if theme.enable_receiver_updates() ~= true then",
  "  ark_test.fail('receiver updates were not enabled')",
  "end",
  "ark_test.wait_for('initial received theme', 5000, function()",
  "  return prompt_color() == '#2255aa'",
  "end)",
  "vim.fn.writefile({ 'initial:' .. tostring(prompt_color()) }, output, 'a')",
  "ark_test.wait_for('updated received theme', 10000, function()",
  "  return prompt_color() == '#aa5522'",
  "end)",
  "vim.fn.writefile({ 'updated:' .. tostring(prompt_color()) }, output, 'a')",
  "stop_watchdog()",
  "vim.cmd('qa!')",
}, child_script)

local child_stderr = {}
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
  env = {
    ARK_NVIM_REPL_THEME_FILE = live_path,
  },
  stderr_buffered = true,
  on_stderr = function(_, data)
    for _, line in ipairs(data or {}) do
      if line ~= "" then
        child_stderr[#child_stderr + 1] = line
      end
    end
  end,
})

if type(child_job) ~= "number" or child_job <= 0 then
  ark_test.fail("failed to start child theme receiver")
end

local function child_output_contains(needle)
  if vim.fn.filereadable(child_output) ~= 1 then
    return false
  end
  for _, line in ipairs(vim.fn.readfile(child_output)) do
    if line == needle then
      return true
    end
  end
  return false
end

ark_test.wait_for("child initial theme receive", 10000, function()
  return child_output_contains("initial:#2255aa")
end)

base_30.green = "#aa5522"
vim.api.nvim_exec_autocmds("User", { pattern = "NvThemeReload" })

ark_test.wait_for("child live theme update", 15000, function()
  return child_output_contains("updated:#aa5522")
end)

local child_exit = vim.fn.jobwait({ child_job }, 5000)[1]
if child_exit == -1 then
  pcall(vim.fn.jobstop, child_job)
  ark_test.fail("child theme receiver did not exit after live update")
elseif child_exit ~= 0 then
  ark_test.fail("child theme receiver failed: " .. vim.inspect({
    exit = child_exit,
    stderr = child_stderr,
  }))
end

local console_frontend = require("ark.console_frontend")
local argv, err = console_frontend.argv({
  console_frontend = "nvim-console",
  launcher = "/tmp/ark-test-launcher",
  nvim_console = {
    bin = "nvim",
    init = "/tmp/ark-test-init.lua",
    add_repo_to_rtp = false,
  },
}, "tmux", nil)
if not argv then
  ark_test.fail("nvim-console argv failed: " .. tostring(err))
end

local saw_theme_cmd = false
local saw_readable_theme = false
for index, value in ipairs(argv) do
  if value == "--cmd" and type(argv[index + 1]) == "string" then
    local theme_path = argv[index + 1]:match("ARK_NVIM_REPL_THEME_FILE%s*=%s*'([^']+)'")
    if type(theme_path) == "string" and theme_path ~= "" then
      saw_theme_cmd = true
      saw_readable_theme = vim.fn.filereadable(theme_path) == 1
    end
  end
end

if not saw_theme_cmd or not saw_readable_theme then
  ark_test.fail("nvim-console argv did not include a readable theme handoff: " .. vim.inspect(argv))
end

vim.print({
  ark_repl_theme_handoff = "ok",
})

stop_watchdog()
