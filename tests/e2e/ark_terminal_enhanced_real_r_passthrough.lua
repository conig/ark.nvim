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
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-real-r-passthrough.jsonl")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { "
  .. "sleep 0.3; printf 'f <- function() { browser(); cat(\"ARK_BROWSER_DONE\\\\n\") }\\n'; "
  .. "sleep 0.5; printf 'f()\\n'; "
  .. "sleep 0.7; printf 'c\\n'; "
  .. "sleep 0.4; printf 'g <- function() { cat(\"ARK_DEBUG_BODY\\\\n\") }\\n'; "
  .. "sleep 0.3; printf 'debugonce(g)\\n'; "
  .. "sleep 0.3; printf 'g()\\n'; "
  .. "sleep 0.7; printf 'c\\n'; "
  .. "sleep 0.4; printf 'q(\"no\")\\n'; "
  .. "} | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- R --quiet --no-save --no-restore'

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal real R pass-through failed: " .. output, 0)
end

if not output:find("Browse[1]> c", 1, true) then
  error("real R browser/debug prompt did not receive pass-through input: " .. output, 0)
end
if not output:find("ARK_BROWSER_DONE", 1, true) then
  error("real R browser() continuation did not execute after pass-through: " .. output, 0)
end
if not output:find("ARK_DEBUG_BODY", 1, true) then
  error("real R debugonce() continuation did not execute after pass-through: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("real R pass-through did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"current":"browser"', 1, true) then
  error("real R trace did not detect browser prompt state: " .. trace, 0)
end
if select(2, trace:gsub('"prompt_state":"browser"', "")) < 2 then
  error("real R trace should forward browser() and debugonce() commands in pass-through mode: " .. trace, 0)
end
