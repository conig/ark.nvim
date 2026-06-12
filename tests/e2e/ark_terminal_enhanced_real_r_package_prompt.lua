vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

if vim.fn.executable("R") ~= 1 then
  error("R is not executable on PATH", 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-real-r-package-prompt.jsonl")
local readonly_lib = vim.fs.normalize(run_tmpdir .. "/readonly-lib")
local home_dir = vim.fs.normalize(run_tmpdir .. "/home")
local user_lib = vim.fs.normalize(run_tmpdir .. "/user-lib")

vim.fn.mkdir(readonly_lib, "p")
vim.fn.mkdir(home_dir, "p")
vim.fn.setfperm(readonly_lib, "r-xr-xr-x")

local function r_string(text)
  text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. text .. '"'
end

local install_code = table.concat({
  'options(repos = c(CRAN = "file:///nonexistent"))',
  ".libPaths(" .. r_string(readonly_lib) .. ")",
  'install.packages("arknotapackage")',
}, "; ")

local script = "{ "
  .. "sleep 0.3; printf "
  .. vim.fn.shellescape(install_code .. "\n")
  .. "; sleep 0.8; printf 'n\\n'; "
  .. "sleep 0.4; printf 'cat(\"INSTALL_PROMPT_DONE\\\\n\")\\n'; "
  .. "sleep 0.3; printf 'q(\"no\")\\n'; "
  .. "} | HOME="
  .. vim.fn.shellescape(home_dir)
  .. " R_LIBS_USER="
  .. vim.fn.shellescape(user_lib)
  .. " "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. " --trace-log "
  .. vim.fn.shellescape(trace_log)
  .. " -- R --quiet --no-save --no-restore"

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal real R package prompt pass-through failed: " .. output, 0)
end

local function strip_ansi(text)
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%].-\7", "")
  return text
end

local plain = strip_ansi(output)
if
  not plain:find(
    "Would you like to use a personal library instead? (yes/No/cancel) n",
    1,
    true
  )
then
  error("real R package install prompt did not receive pass-through input: " .. output, 0)
end
if not plain:find("unable to install packages", 1, true) then
  error(
    "real R package install prompt did not abort after declining personal library: " .. output,
    0
  )
end
if not plain:find("INSTALL_PROMPT_DONE", 1, true) then
  error("R did not return to a usable prompt after package install prompt: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("real R package prompt pass-through did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"bytes":2,"prompt_state":"pass-through"', 1, true) then
  error("package install prompt response should be forwarded in pass-through mode: " .. trace, 0)
end
if not trace:find('"previous":"pass-through","current":"top-level"', 1, true) then
  error("package install prompt should return to top-level prompt after response: " .. trace, 0)
end
