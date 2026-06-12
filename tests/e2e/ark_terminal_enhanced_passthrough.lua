vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-passthrough.jsonl")

local child = table.concat({
  [[printf "Browse[1]> "]],
  [[IFS= read -r browse_line]],
  [[printf "BROWSE:%s\n" "$browse_line"]],
  [[printf "debug> "]],
  [[IFS= read -r debug_line]],
  [[printf "DEBUG:%s\n" "$debug_line"]],
}, "; ")

local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; { sleep 0.2; printf 'n\\n'; sleep 0.2; printf 'Q\\n'; } | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --trace-log "$trace" -- /usr/bin/bash -lc '
  .. vim.fn.shellescape(child)

local output = vim.fn.systemlist({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal enhanced passthrough failed: " .. vim.inspect(output), 0)
end

local joined = table.concat(output, "\n")
if not joined:find("BROWSE:n", 1, true) then
  error("browser-style prompt input was not forwarded: " .. vim.inspect(output), 0)
end
if not joined:find("DEBUG:Q", 1, true) then
  error("debug-style prompt input was not forwarded: " .. vim.inspect(output), 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("enhanced passthrough did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
if not trace:find('"current":"browser"', 1, true) then
  error("trace did not detect browser prompt state: " .. trace, 0)
end
if not trace:find('"current":"debug"', 1, true) then
  error("trace did not detect debug prompt state: " .. trace, 0)
end
if not trace:find('"prompt_state":"browser"', 1, true) then
  error("trace did not forward browser prompt input in pass-through mode: " .. trace, 0)
end
if not trace:find('"prompt_state":"debug"', 1, true) then
  error("trace did not forward debug prompt input in pass-through mode: " .. trace, 0)
end
if trace:find('"event":"enhanced_redraw"', 1, true) then
  error("browser/debug pass-through unexpectedly used local redraw: " .. trace, 0)
end
