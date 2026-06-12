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
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-real-r-prompts.jsonl")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { "
  .. "sleep 0.3; printf 'x <- readline(\"ARK_READLINE_PROMPT: \"); cat(\"READLINE:\", x, \"\\\\n\", sep=\"\")\\n'; "
  .. "sleep 0.5; printf 'typed value\\n'; "
  .. "sleep 0.4; printf 'choice <- menu(c(\"alpha\", \"beta\"), title=\"ARK_MENU_TITLE\"); cat(\"MENU:\", choice, \"\\\\n\", sep=\"\")\\n'; "
  .. "sleep 0.6; printf '2\\n'; "
  .. "sleep 0.4; printf 'sel <- utils::select.list(c(\"left\", \"right\"), graphics=FALSE, title=\"ARK_SELECT_TITLE\"); cat(\"SELECT:\", sel, \"\\\\n\", sep=\"\")\\n'; "
  .. "sleep 0.7; printf '1\\n'; "
  .. "sleep 0.4; printf 'q(\"no\")\\n'; "
  .. "} | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- R --quiet --no-save --no-restore'

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal real R prompt pass-through failed: " .. output, 0)
end

local function strip_ansi(text)
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%].-\7", "")
  return text
end

local plain = strip_ansi(output)
if not plain:find("ARK_READLINE_PROMPT: typed value", 1, true) then
  error("real R readline() did not receive pass-through input: " .. output, 0)
end
if not plain:find("READLINE:typed value", 1, true) then
  error("real R readline() result was not reported: " .. output, 0)
end
if not plain:find("MENU:2", 1, true) then
  error("real R menu() selection was not forwarded: " .. output, 0)
end
if not plain:find("SELECT:left", 1, true) then
  error("real R select.list() selection was not forwarded: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("real R prompt pass-through did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"prompt_state":"pass-through"', 1, true) then
  error("readline() input should be forwarded in pass-through prompt state: " .. trace, 0)
end
if select(2, trace:gsub('"prompt_state":"recover"', "")) < 2 then
  error("menu() and select.list() selections should be forwarded in recover prompt state: " .. trace, 0)
end
