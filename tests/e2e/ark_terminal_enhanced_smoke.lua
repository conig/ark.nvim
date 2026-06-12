vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-enhanced.jsonl")

local child = [[printf "> "; IFS= read -r line; printf "GOT:%s\n" "$line"]]
local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { sleep 0.2; printf 'abc\\n'; } | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- /usr/bin/bash -lc '
  .. vim.fn.shellescape(child)

local output = vim.fn.systemlist({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal enhanced smoke failed: " .. vim.inspect(output), 0)
end

local joined = table.concat(output, "\n")
if not joined:find("GOT:abc", 1, true) then
  error("enhanced smoke did not submit input to child: " .. vim.inspect(output), 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("enhanced smoke did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"event":"enhanced_redraw"', 1, true) then
  error("enhanced smoke trace is missing redraw event: " .. trace, 0)
end
if not trace:find('"event":"enhanced_forward"', 1, true) then
  error("enhanced smoke trace is missing forward event: " .. trace, 0)
end
