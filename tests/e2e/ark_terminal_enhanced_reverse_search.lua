vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-reverse-search.jsonl")

local child = table.concat({
  [[printf "> "]],
  [[IFS= read -r first]],
  [[printf "FIRST:%s\n" "$first"]],
  [[printf "> "]],
  [[IFS= read -r second]],
  [[printf "SECOND:%s\n" "$second"]],
}, "; ")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { sleep 0.2; printf 'alpha()\\n'; sleep 0.2; printf '\\022alp\\n'; } | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- /usr/bin/bash -lc '
  .. vim.fn.shellescape(child)

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal enhanced reverse search failed: " .. output, 0)
end

if not output:find("FIRST:alpha()", 1, true) then
  error("reverse search setup command was not submitted: " .. output, 0)
end
if not output:find("SECOND:alpha()", 1, true) then
  error("reverse search did not submit the matched history entry: " .. output, 0)
end
if not output:find("(reverse-i-search)`alp': alpha()", 1, true) then
  error("reverse search UI was not rendered: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("enhanced reverse search did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"event":"enhanced_reverse_search"', 1, true) then
  error("reverse search trace is missing search event: " .. trace, 0)
end
if not trace:find('"matched":true', 1, true) then
  error("reverse search trace did not record a matched query: " .. trace, 0)
end
if select(2, trace:gsub('"event":"enhanced_forward"', "")) ~= 2 then
  error("reverse search should forward the setup and matched commands: " .. trace, 0)
end
