local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local run_tmpdir = ark_test.run_tmpdir()
local pid_path = vim.fs.normalize(run_tmpdir .. "/detached-child.pid")
local started_path = vim.fs.normalize(run_tmpdir .. "/detached-child.started")
local script_path = vim.fs.normalize(run_tmpdir .. "/detached-child.sh")
vim.fn.mkdir(run_tmpdir, "p")

local function sh_quote(value)
  return "'" .. tostring(value):gsub("'", [["'"']]) .. "'"
end

vim.fn.writefile({
  "#!/usr/bin/env bash",
  "trap 'exit 0' TERM INT",
  'echo $$ > "' .. pid_path .. '"',
  'echo ready > "' .. started_path .. '"',
  "while :; do /usr/bin/sleep 1; done",
}, script_path)

local launcher = string.format(
  "nohup /usr/bin/setsid -f /usr/bin/bash %s >/dev/null 2>&1 < /dev/null &",
  sh_quote(script_path)
)

local job_id = vim.fn.jobstart({ "/usr/bin/bash", "-lc", launcher }, {
  clear_env = false,
  env = {
    ARK_TEST_RUN_ID = tostring(vim.env.ARK_TEST_RUN_ID or ""),
    ARK_TEST_TMPDIR = run_tmpdir,
  },
})

if job_id <= 0 then
  ark_test.fail("failed to launch detached child job: " .. tostring(job_id))
end

ark_test.wait_for("detached child pid file", 5000, function()
  return vim.fn.filereadable(pid_path) == 1 and vim.fn.filereadable(started_path) == 1
end)

vim.wait(30000, function()
  return false
end, 100, false)
