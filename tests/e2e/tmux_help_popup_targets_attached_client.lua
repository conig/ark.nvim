vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.tmux"] = nil

local original_help_width_env = vim.env.ARK_NVIM_HELP_POPUP_WIDTH
vim.env.ARK_NVIM_HELP_POPUP_WIDTH = nil
package.loaded["ark.config"] = nil
local defaults = require("ark.config").defaults()
local default_popup_width = defaults.help.popup.width
local default_popup_viewer = defaults.help.popup.viewer
vim.env.ARK_NVIM_HELP_POPUP_WIDTH = original_help_width_env
package.loaded["ark.config"] = nil
if default_popup_width ~= "auto" then
  error("expected default ArkHelp tmux popup width to be auto, got " .. tostring(default_popup_width), 0)
end
if default_popup_viewer ~= "nvim" then
  error("expected default ArkHelp tmux popup viewer to use the Neovim backend, got " .. tostring(default_popup_viewer), 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")

local fake_bin = vim.fs.normalize(run_tmpdir .. "/bin")
vim.fn.mkdir(fake_bin, "p")

local log_path = vim.fs.normalize(run_tmpdir .. "/tmux.log")
local fake_tmux = vim.fs.normalize(fake_bin .. "/tmux")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "set -euo pipefail",
  "log=" .. vim.fn.shellescape(log_path),
  "if [[ \"${1:-}\" == \"-S\" ]]; then shift 2; fi",
  "printf 'CALL' >> \"$log\"",
  "for arg in \"$@\"; do printf '\\t%s' \"$arg\" >> \"$log\"; done",
  "printf '\\n' >> \"$log\"",
  "case \"${1:-}\" in",
  "  display-message)",
  "    last=\"${@: -1}\"",
  "    if [[ \"$last\" == '#{pane_id}' ]]; then printf '%%source\\n'; exit 0; fi",
  "    if [[ \"$last\" == '#{session_name}' ]]; then printf 'ark_session\\n'; exit 0; fi",
  "    if [[ \"$last\" == '#{client_width}' ]]; then printf '120\\n'; exit 0; fi",
  "    printf 'ark_session\\n'",
  "    ;;",
  "  list-clients)",
  "    printf '/dev/pts/9\\tark_session\\n/dev/pts/10\\tother_session\\n'",
  "    ;;",
  "  display-popup)",
  "    exit 0",
  "    ;;",
  "esac",
}, fake_tmux)
vim.fn.setfperm(fake_tmux, "rwxr-xr-x")

local original_path = vim.env.PATH
local original_socket = vim.env.ARK_TMUX_SOCKET
local original_tmux = vim.env.TMUX
local original_jobstart = vim.fn.jobstart
local jobstart_calls = {}

vim.env.PATH = fake_bin .. ":" .. (original_path or "")
vim.env.ARK_TMUX_SOCKET = "/tmp/ark-popup-test.sock"
vim.env.TMUX = ""
vim.fn.jobstart = function(command, opts)
  jobstart_calls[#jobstart_calls + 1] = {
    command = vim.deepcopy(command),
    opts = vim.deepcopy(opts or {}),
  }
  return 420
end

local ok, err = pcall(function()
  local tmux = require("ark.tmux")

  local function popup_arg(command, flag)
    for index, value in ipairs(command) do
      if value == flag then
        return command[index + 1]
      end
    end
    return nil
  end

  local function has_popup_flag(command, flag)
    for _, value in ipairs(command) do
      if value == flag then
        return true
      end
    end
    return false
  end

  local function popup_shell_command(command)
    for index, value in ipairs(command) do
      if value == "-T" then
        return command[index + 2], #command - index - 1
      end
    end
    return command[#command], 1
  end

  local function popup_script_text(command)
    local script, count = popup_shell_command(command)
    if count ~= 1 or type(script) ~= "string" or script == "" then
      error("expected popup to pass one launcher script to tmux, got " .. vim.inspect(command), 0)
    end
    if not script:find("%.arkhelp%-popup%.sh$", 1, false) then
      error("expected ArkHelp popup command to use a temp launcher script, got " .. script, 0)
    end
    if script:find("/nvim%.", 1, false) then
      error("ArkHelp popup launcher must not live under Neovim's auto-cleaned temp dir, got " .. script, 0)
    end
    return table.concat(vim.fn.readfile(script), "\n")
  end

  local function popup_bootstrap(script_text)
    local bootstrap = script_text:match("([^%s'\"]+%.arkhelp%.lua)")
    if not bootstrap then
      error("expected ArkHelp popup launcher to load a link bootstrap script, got " .. script_text, 0)
    end
    return bootstrap, table.concat(vim.fn.readfile(bootstrap), "\n")
  end

  local default_popup_ok, default_popup_err = tmux.help_popup({}, "Default viewer\n", {
    target = "%source",
    title = "ArkHelp: default viewer",
  })
  if not default_popup_ok then
    error("expected default ArkHelp popup viewer to succeed: " .. tostring(default_popup_err), 0)
  end
  if #jobstart_calls ~= 1 then
    error("expected one default ArkHelp popup call, got " .. vim.inspect(jobstart_calls), 0)
  end
  local default_popup_command = table.concat(jobstart_calls[1].command, "\t")
  if not default_popup_command:find("\tdisplay%-popup\t", 1, false) then
    error("expected default ArkHelp popup to use display-popup, got " .. default_popup_command, 0)
  end
  local default_popup_script = popup_script_text(jobstart_calls[1].command)
  if not default_popup_script:find("nvim", 1, true) then
    error("default ArkHelp popup should launch the Neovim backend, got " .. default_popup_script, 0)
  end
  if default_popup_script:find("less", 1, true) then
    error("default ArkHelp popup should not use the pager backend, got " .. default_popup_script, 0)
  end
  if jobstart_calls[1].opts.detach ~= true then
    error("default ArkHelp popup should launch the Neovim backend detached, got " .. vim.inspect(jobstart_calls[1].opts), 0)
  end
  if not default_popup_command:find("\t%-e\tTERM=ansi\t", 1, false) then
    error("default ArkHelp popup should disable alternate-screen for the Neovim backend, got " .. default_popup_command, 0)
  end

  jobstart_calls = {}
  local popup_ok, popup_err = tmux.help_popup({}, "Fitting Linear Models\n", {
    target = "%source",
    title = "ArkHelp: lm",
    width = "80%",
    height = "70%",
    viewer = "nvim",
    nvim = {
      bin = "nvim",
      init = "NONE",
    },
    help = {
      server = "/tmp/ark-help-popup.sock",
      backend_id = "ark-help-popup-test",
      rpc_name = "__ark_help_popup_backend",
      initial = {
        references = {
          {
            line = 1,
            start_col = 0,
            end_col = 6,
            target = "stats::lm",
          },
        },
      },
    },
  })

  if not popup_ok then
    error("expected fake tmux popup to succeed: " .. tostring(popup_err), 0)
  end

  if #jobstart_calls ~= 1 then
    error("expected display-popup to be launched asynchronously, got " .. vim.inspect(jobstart_calls), 0)
  end

  local popup_command = table.concat(jobstart_calls[1].command, "\t")
  local popup_shell, popup_shell_count = popup_shell_command(jobstart_calls[1].command)
  if popup_shell_count ~= 1
    or type(popup_shell) ~= "string"
    or not popup_shell:find("%.arkhelp%-popup%.sh$", 1, false)
  then
    error("ArkHelp popup should pass one launcher script to tmux so Neovim receives its arguments, got " .. popup_command, 0)
  end
  if popup_shell:find("/nvim%.", 1, false) then
    error("ArkHelp popup launcher must not live under Neovim's auto-cleaned temp dir, got " .. popup_shell, 0)
  end
  local popup_script = table.concat(vim.fn.readfile(popup_shell), "\n")
  if not popup_command:find("\tdisplay%-popup\t", 1, false) then
    error("expected async display-popup command, got " .. popup_command, 0)
  end

  if not popup_command:find("\t%-c\t/dev/pts/9\t", 1, false) then
    error("expected ArkHelp popup to target attached client /dev/pts/9, got " .. popup_command, 0)
  end

  if not popup_command:find("\t%-e\tTERM=ansi\t", 1, false) then
    error("expected ArkHelp popup to disable terminal alternate-screen via TERM=ansi, got " .. popup_command, 0)
  end

  if popup_arg(jobstart_calls[1].command, "-x") ~= "C" or popup_arg(jobstart_calls[1].command, "-y") ~= "C" then
    error("expected ArkHelp popup to be centered on both axes, got " .. popup_command, 0)
  end
  if has_popup_flag(jobstart_calls[1].command, "-B") then
    error("expected ArkHelp popup to keep tmux border chrome for its title, got " .. popup_command, 0)
  end
  if popup_arg(jobstart_calls[1].command, "-T") ~= "ArkHelp: lm" then
    error("expected ArkHelp popup title to be passed to tmux, got " .. popup_command, 0)
  end

  if popup_command:find("\t%-t\t%%source\t", 1, false) then
    error("expected client-targeted ArkHelp popup to avoid pane-relative -t geometry, got " .. popup_command, 0)
  end

  if not popup_script:find("stopinsert", 1, true) then
    error("expected popup Neovim to force normal mode with stopinsert, got " .. popup_script, 0)
  end

  if not popup_script:find("laststatus=0", 1, true) then
    error("expected popup Neovim to hide its statusline, got " .. popup_script, 0)
  end

  if not popup_script:find("cmdheight=0", 1, true) then
    error("expected popup Neovim to hide its command/status area with cmdheight=0, got " .. popup_script, 0)
  end

  if not popup_script:find("filetype=markdown", 1, true) then
    error("expected ArkHelp popup buffer to use markdown filetype for fenced R example highlighting, got " .. popup_script, 0)
  end
  if not popup_script:find("markdown_fenced_languages", 1, true) or not popup_script:find("syntax/markdown.vim", 1, true) then
    error("expected ArkHelp popup buffer to enable markdown fenced R syntax highlighting, got " .. popup_script, 0)
  end
  local popup_bootstrap_path, popup_bootstrap_text = popup_bootstrap(popup_script)
  if not popup_bootstrap_text:find("__ark_help_popup_backend", 1, true)
    or not popup_bootstrap_text:find("sockconnect", 1, true)
  then
    error("expected ArkHelp popup to request followed links from the parent Neovim, got " .. popup_bootstrap_text, 0)
  end
  if not popup_bootstrap_text:find("ArkHelpReference", 1, true)
    or not popup_bootstrap_text:find("underline", 1, true)
    or not popup_bootstrap_text:find("bold", 1, true)
  then
    error("expected ArkHelp popup links to be styled in the child Neovim, got " .. popup_bootstrap_text, 0)
  end
  if not popup_bootstrap_text:find("<CR>", 1, true) or not popup_bootstrap_text:find("reference_under_cursor", 1, true) then
    error("expected ArkHelp popup Enter to follow the reference under cursor, got " .. popup_bootstrap_text, 0)
  end

  local bootstrap_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(bootstrap_buf)
  vim.api.nvim_buf_set_lines(bootstrap_buf, 0, -1, false, { "stats lm" })
  local bootstrap_ok, bootstrap_err = pcall(vim.cmd, "luafile " .. vim.fn.fnameescape(popup_bootstrap_path))
  if not bootstrap_ok then
    error("expected generated ArkHelp popup bootstrap to execute: " .. tostring(bootstrap_err), 0)
  end
  local bootstrap_refs = vim.b[bootstrap_buf].ark_help_references or {}
  if type(bootstrap_refs[1]) ~= "table" or bootstrap_refs[1].target ~= "stats::lm" then
    error("expected generated ArkHelp popup bootstrap to install references, got " .. vim.inspect(bootstrap_refs), 0)
  end

  -- Regression: closing ArkHelp must ask tmux to remove the popup before
  -- Neovim exits, otherwise Neovim's terminal teardown can visibly redraw the
  -- panes underneath the popup.
  if not popup_script:find("display%-popup", 1, false) or not popup_script:find("%-C", 1, false) then
    error("expected ArkHelp close mapping to close the tmux popup before Neovim exits, got " .. popup_script, 0)
  end
  if not popup_script:find("nnoremap <buffer><silent> q ", 1, true) then
    error("expected ArkHelp popup to close from normal-mode q, got " .. popup_script, 0)
  end
  if popup_script:find("nnoremap <buffer><silent> <Esc>", 1, true) then
    error("expected ArkHelp popup to leave Escape unbound for close, got " .. popup_script, 0)
  end

  local _, laststatus_count = popup_script:gsub("laststatus=0", "")
  if laststatus_count < 2 then
    error("expected popup Neovim to enforce laststatus=0 after user config loads, got " .. popup_script, 0)
  end

  if popup_script:find("sh %-lc", 1, false) then
    error("ArkHelp popup launcher script should invoke Neovim directly instead of nesting shell parsing, got " .. popup_script, 0)
  end

  if not popup_script:find("rm %-f %-%-", 1, false) then
    error("ArkHelp popup launcher should clean temp files after Neovim exits, got " .. popup_script, 0)
  end

  if not popup_script:find("VimLeavePre", 1, true) or not popup_script:find("delete", 1, true) then
    error("expected ArkHelp popup Neovim to clean its temp file from VimLeavePre, got " .. popup_script, 0)
  end

  if popup_arg(jobstart_calls[1].command, "-w") ~= "80%" then
    error("expected explicit ArkHelp popup width to be preserved, got " .. popup_command, 0)
  end

  jobstart_calls = {}
  local auto_popup_ok, auto_popup_err = tmux.help_popup({}, "Short\n" .. string.rep("x", 54) .. "\n", {
    target = "%source",
    title = "ArkHelp: auto width",
    viewer = "nvim",
    nvim = {
      bin = "nvim",
      init = "NONE",
    },
  })

  if not auto_popup_ok then
    error("expected fake tmux auto-width popup to succeed: " .. tostring(auto_popup_err), 0)
  end
  if #jobstart_calls ~= 1 then
    error("expected one auto-width display-popup call, got " .. vim.inspect(jobstart_calls), 0)
  end

  local auto_width = popup_arg(jobstart_calls[1].command, "-w")
  if auto_width ~= "58" then
    error("expected ArkHelp popup default width to fit 54-cell content plus margin, got " .. tostring(auto_width), 0)
  end

  jobstart_calls = {}
  local ui_popup_ok, ui_popup_err = tmux.view_popup({}, "/tmp/ark-console.sock", "ark-view-test", "mtcars", {
    target = "%source",
    title = "ArkView: mtcars",
    width = "91%",
    height = "83%",
    nvim = {
      bin = "nvim",
    },
  })
  if not ui_popup_ok then
    error("expected fake tmux ArkView popup to succeed: " .. tostring(ui_popup_err), 0)
  end
  if #jobstart_calls ~= 1 then
    error("expected one ArkView popup display-popup call, got " .. vim.inspect(jobstart_calls), 0)
  end

  local ui_popup_command = table.concat(jobstart_calls[1].command, "\t")
  local ui_popup_shell, ui_popup_shell_count = popup_shell_command(jobstart_calls[1].command)
  if ui_popup_shell_count ~= 1 or type(ui_popup_shell) ~= "string" or ui_popup_shell == "" then
    error("ArkView popup should pass one shell command string to tmux so Neovim receives its arguments, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("\tdisplay%-popup\t", 1, false) then
    error("expected ArkView popup to use display-popup, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("\t%-c\t/dev/pts/9\t", 1, false) then
    error("expected ArkView popup to target attached client /dev/pts/9, got " .. ui_popup_command, 0)
  end
  if popup_arg(jobstart_calls[1].command, "-w") ~= "91%" or popup_arg(jobstart_calls[1].command, "-h") ~= "83%" then
    error("unexpected ArkView popup geometry: " .. ui_popup_command, 0)
  end
  if popup_arg(jobstart_calls[1].command, "-x") ~= "C" or popup_arg(jobstart_calls[1].command, "-y") ~= "C" then
    error("expected ArkView popup to be centered on both axes, got " .. ui_popup_command, 0)
  end
  if has_popup_flag(jobstart_calls[1].command, "-B") then
    error("expected ArkView popup to keep tmux border chrome for its title, got " .. ui_popup_command, 0)
  end
  if popup_arg(jobstart_calls[1].command, "-T") ~= "ArkView: mtcars" then
    error("expected ArkView popup title to be passed to tmux, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("nvim", 1, true)
    or not ui_popup_command:find("luafile", 1, true)
    or not ui_popup_command:find("/tmp/ark%-console%.sock", 1, false)
    or not ui_popup_command:find("ark%-view%-test", 1, false)
  then
    error("expected ArkView popup to launch a standalone Neovim bootstrap, got " .. ui_popup_command, 0)
  end
  if ui_popup_command:find("%-%-remote%-ui", 1, false) or ui_popup_command:find("%-%-server", 1, false) then
    error("ArkView popup must not attach a remote UI to the source Neovim, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("%.arkview%-startup", 1, false) then
    error("ArkView popup should start Neovim with a named buffer so startup dashboards stay idle, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("laststatus=0", 1, true) then
    error("ArkView popup should hide Neovim chrome before startup draws, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("cmdheight=0", 1, true) then
    error("ArkView popup should hide the command area before startup draws, got " .. ui_popup_command, 0)
  end
  if not ui_popup_command:find("shortmess%+=I", 1, false) then
    error("ArkView popup should suppress the startup intro before startup draws, got " .. ui_popup_command, 0)
  end
  local startup_path = ui_popup_command:match("([^%s']+%.arkview%-startup)")
  if not startup_path then
    error("expected ArkView popup command to expose the startup buffer path, got " .. ui_popup_command, 0)
  end
  local startup_lines = vim.fn.readfile(startup_path)
  if #startup_lines ~= 0 then
    error("ArkView popup startup buffer should be empty to avoid pre-grid flicker, got " .. vim.inspect(startup_lines), 0)
  end
  local bootstrap_path = ui_popup_command:match("luafile%s+([^%s']+%.arkview%.lua)")
  if not bootstrap_path then
    error("expected ArkView popup command to expose the bootstrap script path, got " .. ui_popup_command, 0)
  end
  local bootstrap = table.concat(vim.fn.readfile(bootstrap_path), "\n")
  if not bootstrap:find("nvdash", 1, true) or not bootstrap:find("load_on_startup", 1, true) then
    error("ArkView popup bootstrap should disable startup dashboards before opening ArkView, got " .. bootstrap, 0)
  end
  if not bootstrap:find("display%-popup", 1, false) or not bootstrap:find("%-C", 1, false) then
    error("ArkView popup should ask tmux to close the popup before Neovim exits, got " .. bootstrap, 0)
  end
  local close_pos = bootstrap:find("close_popup%(%).*vim%.defer_fn.*qa!", 1, false)
  if not close_pos then
    error("ArkView popup close path should close tmux before qa!, got " .. bootstrap, 0)
  end

  jobstart_calls = {}
  local nvim_ui_popup_ok, nvim_ui_popup_err = tmux.nvim_ui_popup({}, "/tmp/ark-source.sock", {
    target = "%source",
    title = "Ark source UI",
    width = "92%",
    height = "84%",
    nvim = {
      bin = "nvim",
    },
  })
  if not nvim_ui_popup_ok then
    error("expected fake tmux Neovim UI popup to succeed: " .. tostring(nvim_ui_popup_err), 0)
  end
  if #jobstart_calls ~= 1 then
    error("expected one Neovim UI popup display-popup call, got " .. vim.inspect(jobstart_calls), 0)
  end
  local nvim_ui_popup_command = table.concat(jobstart_calls[1].command, "\t")
  if popup_arg(jobstart_calls[1].command, "-x") ~= "C" or popup_arg(jobstart_calls[1].command, "-y") ~= "C" then
    error("expected Neovim UI popup to be centered on both axes, got " .. nvim_ui_popup_command, 0)
  end
  if has_popup_flag(jobstart_calls[1].command, "-B") then
    error("expected Neovim UI popup to keep tmux border chrome for its title, got " .. nvim_ui_popup_command, 0)
  end
  if popup_arg(jobstart_calls[1].command, "-T") ~= "Ark source UI" then
    error("expected Neovim UI popup title to be passed to tmux, got " .. nvim_ui_popup_command, 0)
  end

  jobstart_calls = {}
  local borderless_popup_ok, borderless_popup_err = tmux.nvim_ui_popup({}, "/tmp/ark-source.sock", {
    target = "%source",
    title = "Ark borderless override",
    width = "92%",
    height = "84%",
    border = false,
    nvim = {
      bin = "nvim",
    },
  })
  if not borderless_popup_ok then
    error("expected fake borderless Neovim UI popup to succeed: " .. tostring(borderless_popup_err), 0)
  end
  if #jobstart_calls ~= 1 then
    error("expected one borderless Neovim UI popup display-popup call, got " .. vim.inspect(jobstart_calls), 0)
  end
  local borderless_popup_command = table.concat(jobstart_calls[1].command, "\t")
  if not has_popup_flag(jobstart_calls[1].command, "-B") then
    error("expected explicit border=false to disable tmux border chrome, got " .. borderless_popup_command, 0)
  end
  if popup_arg(jobstart_calls[1].command, "-T") ~= "Ark borderless override" then
    error("expected borderless Neovim UI popup title to still be passed to tmux, got " .. borderless_popup_command, 0)
  end
end)

vim.fn.jobstart = original_jobstart
vim.env.PATH = original_path
vim.env.ARK_TMUX_SOCKET = original_socket
vim.env.TMUX = original_tmux
vim.fn.delete(run_tmpdir, "rf")
local tmpdir = vim.env.TMPDIR
if type(tmpdir) ~= "string" or tmpdir == "" then
  tmpdir = "/tmp"
end
tmpdir = tmpdir:gsub("/+$", "")
for _, path in ipairs(vim.fn.glob(vim.fs.normalize(tmpdir .. "/ark-nvim-popup-" .. tostring(vim.fn.getpid()) .. "-*"), false, true)) do
  vim.fn.delete(path)
end

if not ok then
  error(err, 0)
end
