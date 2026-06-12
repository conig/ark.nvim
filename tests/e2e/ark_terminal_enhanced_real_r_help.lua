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
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-real-r-help.jsonl")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { "
  .. "sleep 0.3; printf 'options(help_type=\"text\")\\n'; "
  .. "sleep 0.3; printf 'help(\"mean\")\\n'; "
  .. "sleep 0.8; printf 'cat(\"ARK_TEXT_HELP_DONE\\\\n\")\\n'; "
  .. "sleep 0.3; printf 'q(\"no\")\\n'; "
  .. "} | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- R --quiet --no-save --no-restore'

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal real R text help failed: " .. output, 0)
end

local function strip_ansi(text)
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%].-\7", "")
  return text
end

local plain = strip_ansi(output)
if not plain:find("mean                   package:base", 1, true) then
  error("real R text help output was not rendered: " .. output, 0)
end
if not plain:find("ARK_TEXT_HELP_DONE", 1, true) then
  error("real R did not return to a usable prompt after text help: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("real R text help did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"current":"pass-through"', 1, true) then
  error("text help output should move prompt state to pass-through while rendering: " .. trace, 0)
end

local function count_plain(text, pattern)
  local count = 0
  local start = 1
  while true do
    local found = text:find(pattern, start, true)
    if found == nil then
      return count
    end
    count = count + 1
    start = found + #pattern
  end
end

if count_plain(trace, '"current":"top-level"') < 2 then
  error("text help should return to a top-level prompt after output: " .. trace, 0)
end
