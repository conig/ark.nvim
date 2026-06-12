vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

if vim.fn.executable("R") ~= 1 then
  error("R is not executable on PATH", 0)
end
if vim.fn.executable("less") ~= 1 then
  error("less is not executable on PATH", 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-real-r-child-process.jsonl")
local child_script = vim.fs.normalize(run_tmpdir .. "/ark-child-process.sh")
local less_file = vim.fs.normalize(run_tmpdir .. "/ark-less.txt")

vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf 'ARK_CHILD_PROMPT: '",
  "IFS= read -r ans",
  "printf 'ARK_CHILD:%s\\n' \"$ans\"",
}, child_script)
vim.fn.setfperm(child_script, "rwxr-xr-x")

local less_lines = {}
for index = 1, 120 do
  less_lines[index] = string.format("ARK_LESS_LINE_%03d", index)
end
vim.fn.writefile(less_lines, less_file)

local function r_string(text)
  text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. text .. '"'
end

local child_command = vim.fn.shellescape(child_script)
local less_command = "less -X " .. vim.fn.shellescape(less_file)

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { "
  .. "sleep 0.3; printf "
  .. vim.fn.shellescape("system(" .. r_string(child_command) .. ")\n")
  .. "; sleep 0.7; printf 'child-value\\n'; "
  .. "sleep 0.4; printf 'cat(\"ARK_CHILD_DONE\\\\n\")\\n'; "
  .. "sleep 0.3; printf "
  .. vim.fn.shellescape("system(" .. r_string(less_command) .. ")\n")
  .. "; sleep 1.0; printf 'q'; "
  .. "sleep 0.4; printf 'cat(\"ARK_LESS_DONE\\\\n\")\\n'; "
  .. "sleep 0.3; printf 'q(\"no\")\\n'; "
  .. "} | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- R --quiet --no-save --no-restore'

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal real R child process pass-through failed: " .. output, 0)
end

local function strip_ansi(text)
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub("\27%].-\7", "")
  return text
end

local plain = strip_ansi(output)
if not plain:find("ARK_CHILD_PROMPT: child-value", 1, true) then
  error("child process prompt did not receive pass-through input: " .. output, 0)
end
if not plain:find("ARK_CHILD:child-value", 1, true) then
  error("child process did not report the pass-through input: " .. output, 0)
end
if not plain:find("ARK_CHILD_DONE", 1, true) then
  error("R did not return to a usable prompt after child process: " .. output, 0)
end
if not plain:find("ARK_LESS_LINE_001", 1, true) then
  error("less pager output was not rendered: " .. output, 0)
end
if not plain:find("ARK_LESS_DONE", 1, true) then
  error("R did not return to a usable prompt after less pager: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("real R child process pass-through did not write trace log: " .. trace_log, 0)
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

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if count_plain(trace, '"prompt_state":"pass-through"') < 2 then
  error("child process and pager input should be forwarded in pass-through mode: " .. trace, 0)
end
if count_plain(trace, '"current":"top-level"') < 2 then
  error("R should return to top-level prompts after child process and pager: " .. trace, 0)
end
