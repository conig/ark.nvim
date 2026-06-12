vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-multiline.jsonl")

local child = table.concat({
  [[printf "> "]],
  [[IFS= read -r first]],
  [[IFS= read -r second]],
  [[IFS= read -r third]],
  [[printf "LINES:%s|%s|%s\n" "$first" "$second" "$third"]],
}, "; ")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { sleep 0.2; printf 'if (TRUE) {\\n'; sleep 0.1; printf '1\\n'; sleep 0.1; printf '}\\n'; } | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- /usr/bin/bash -lc '
  .. vim.fn.shellescape(child)

local output = vim.fn.system({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal enhanced multiline failed: " .. output, 0)
end

if not output:find("LINES:if (TRUE) {|1|}", 1, true) then
  error("enhanced multiline did not submit the complete block: " .. output, 0)
end

if not output:find("\r\n+ ", 1, true) then
  error("enhanced multiline did not render a continuation prompt: " .. output, 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("enhanced multiline did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if select(2, trace:gsub('"event":"enhanced_forward"', "")) ~= 1 then
  error("enhanced multiline should forward exactly once after completion: " .. trace, 0)
end
if select(2, trace:gsub('"event":"enhanced_redraw"', "")) < 3 then
  error("enhanced multiline should redraw while editing locally: " .. trace, 0)
end
