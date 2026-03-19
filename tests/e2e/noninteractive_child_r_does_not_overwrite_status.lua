local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

local function read_status(path)
  local lines = vim.fn.readfile(path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local function prompt_ready(pane_id)
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  local last_line = ""
  for line in (capture .. "\n"):gmatch("(.-)\n") do
    if line:match("%S") then
      last_line = line
    end
  end
  return last_line == ">" or last_line == "> "
end

local test_file = "/tmp/ark_noninteractive_child_r_status.R"
local pane_id = ark_test.setup_managed_buffer(test_file, {
  "x <- 1",
})

local status = require("ark").status()
local status_path = status.startup_status_path
if type(status_path) ~= "string" or status_path == "" then
  fail("missing startup status path")
end

local initial = read_status(status_path)
if initial.repl_ready ~= true then
  fail("expected initial repl_ready=true, got: " .. vim.inspect(initial))
end

if type(initial.pid) ~= "number" or initial.pid <= 0 then
  fail("expected initial launcher pid in status file, got: " .. vim.inspect(initial))
end

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  "-l",
  'system2("R", c("--no-echo", "--no-restore", "--no-save", "-e", "Sys.sleep(1)"), stdout = FALSE, stderr = FALSE)',
})
ark_test.tmux({ "send-keys", "-t", pane_id, "Enter" })

ark_test.wait_for("noninteractive child R to finish", 10000, function()
  return prompt_ready(pane_id)
end)

local final = read_status(status_path)

if final.pid ~= initial.pid then
  fail("noninteractive child R overwrote pane status pid: " .. vim.inspect({
    initial = initial,
    final = final,
  }))
end

if final.repl_ready ~= true then
  fail("noninteractive child R cleared repl_ready: " .. vim.inspect({
    initial = initial,
    final = final,
  }))
end

vim.print({
  initial = initial,
  final = final,
})
