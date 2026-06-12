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
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-real-r.jsonl")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { "
  .. "sleep 0.3; printf 'cat(\"ARK_REAL_TOP\\\\n\")\\n'; "
  .. "sleep 0.3; printf 'if (TRUE) {\\ncat(\"ARK_REAL_MULTI\\\\n\")\\n}\\n'; "
  .. "sleep 0.3; printf 'q(\"no\")\\n'; "
  .. "} | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- R --quiet --no-save --no-restore'

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal real R enhanced editing failed: " .. output, 0)
end

if not output:find("ARK_REAL_TOP", 1, true) then
  error("real R top-level command did not execute: " .. output, 0)
end
if not output:find("ARK_REAL_MULTI", 1, true) then
  error("real R multiline command did not execute: " .. output, 0)
end
if not output:find("\r\n+ ", 1, true) then
  error("real R multiline input did not render a local continuation prompt: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("real R enhanced editing did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"current":"top-level"', 1, true) then
  error("real R trace did not detect top-level prompt: " .. trace, 0)
end
if select(2, trace:gsub('"event":"enhanced_forward"', "")) < 3 then
  error("real R trace should forward top-level, multiline, and quit commands: " .. trace, 0)
end
