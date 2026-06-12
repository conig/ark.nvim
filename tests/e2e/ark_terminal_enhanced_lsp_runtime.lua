vim.opt.rtp:prepend(vim.fn.getcwd())

local repo_root = vim.fn.getcwd()
local ark_terminal_bin = vim.fs.normalize(repo_root .. "/target/debug/ark-terminal")
if vim.fn.executable(ark_terminal_bin) ~= 1 then
  error("ark-terminal binary is not built or executable: " .. ark_terminal_bin, 0)
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local trace_log = vim.fs.normalize(run_tmpdir .. "/ark-terminal-lsp.jsonl")
local fake_lsp = vim.fs.normalize(run_tmpdir .. "/fake-lsp")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "exec cat",
}, fake_lsp)
vim.fn.setfperm(fake_lsp, "rwx------")

local child = [[printf "> "; IFS= read -r line; printf "GOT:%s\n" "$line"]]
local script = "trace="
  .. vim.fn.shellescape(trace_log)
  .. "; lsp="
  .. vim.fn.shellescape(fake_lsp)
  .. "; { sleep 0.2; printf 'mtcars$'; sleep 0.4; printf '\\n'; sleep 0.1; } | "
  .. vim.fn.shellescape(ark_terminal_bin)
  .. ' --ark-lsp "$lsp" --trace-log "$trace" -- /usr/bin/bash -lc '
  .. vim.fn.shellescape(child)

local output = vim.fn.systemlist({ "/usr/bin/bash", "-lc", script })
if vim.v.shell_error ~= 0 then
  error("ark-terminal enhanced LSP runtime failed: " .. vim.inspect(output), 0)
end

local joined = table.concat(output, "\n")
if not joined:find("GOT:mtcars$", 1, true) then
  error("enhanced LSP runtime did not submit input to child: " .. vim.inspect(output), 0)
end

if vim.fn.filereadable(trace_log) ~= 1 then
  error("enhanced LSP runtime did not write trace log: " .. trace_log, 0)
end

local trace = table.concat(vim.fn.readfile(trace_log), "\n")
for _, event in ipairs({
  '"event":"lsp_worker_spawned"',
  '"event":"lsp_child_started"',
  '"event":"lsp_initialized"',
  '"event":"lsp_snapshot_synced"',
  '"event":"lsp_completion_request"',
  '"event":"lsp_completion_response"',
}) do
  if not trace:find(event, 1, true) then
    error("enhanced LSP runtime trace missing " .. event .. ": " .. trace, 0)
  end
end

if not trace:find('"trigger_character":"$"', 1, true) then
  error("enhanced LSP runtime trace did not preserve trigger character: " .. trace, 0)
end
