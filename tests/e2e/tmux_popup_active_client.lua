vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile("tests/e2e/ark_test.lua")
local stop_watchdog = ark_test.start_watchdog(30000, "tmux_popup_active_client")
local socket = assert(vim.env.ARK_TMUX_SOCKET)
local session = assert(vim.env.ARK_TMUX_SESSION)
local pane = assert(vim.env.ARK_TMUX_ANCHOR_PANE)
local jobs = {}
local original_jobstart = vim.fn.jobstart
local popup_command

local function clients()
  local result = {}
  for line in ark_test.tmux({ "list-clients", "-F", "#{client_name}\t#{client_pid}\t#{client_flags}" }):gmatch("[^\n]+") do
    local name, pid, flags = line:match("^([^\t]+)\t(%d+)\t(.*)$")
    result[tonumber(pid)] = { name = name, flags = flags }
  end
  return result
end

local function attach(control)
  local command = { "tmux", "-S", socket }
  if control then
    command[#command + 1] = "-C"
  end
  vim.list_extend(command, { "attach-session", "-t", session })
  local job = original_jobstart(command, {
    pty = not control,
    width = 100,
    height = 35,
    env = { TERM = "xterm-256color", TMUX = "" },
  })
  assert(job > 0, "failed to attach test client")
  jobs[#jobs + 1] = job
  local pid = vim.fn.jobpid(job)
  ark_test.wait_for("attached test client", 5000, function()
    return clients()[pid] ~= nil
  end)
  return job, pid
end

local function expect_target(pid)
  local opened, open_err = require("ark.tmux").view_popup({}, "/tmp/test-parent.sock", "test-backend", "x", {
    target = pane,
    nvim = { init = "NONE" },
  })
  assert(opened, open_err)
  local selected
  for index, value in ipairs(popup_command or {}) do
    if value == "-c" then
      selected = popup_command[index + 1]
      break
    end
  end
  local expected = clients()[pid].name
  assert(selected == expected, "ArkView targeted inactive client " .. tostring(selected) .. " instead of " .. expected)
end

local ok, err = xpcall(function()
  ark_test.tmux({ "set-option", "-s", "focus-events", "on" })
  local first, first_pid = attach()
  local second, second_pid = attach()
  -- Real terminal focus reports reproduce two terminals on the same session:
  -- the older, first-listed terminal must not steal the active terminal's View.
  vim.fn.chansend(first, "\27[O")
  vim.fn.chansend(second, "\27[I")
  ark_test.wait_for("second client focused", 5000, function()
    local current = clients()
    return not current[first_pid].flags:find("focused", 1, true) and current[second_pid].flags:find("focused", 1, true)
  end)

  -- Keep all tmux discovery real; only intercept the final visible popup so
  -- this headless test neither launches a UI nor depends on a live R session.
  vim.fn.jobstart = function(command, opts)
    if type(command) == "table" and vim.tbl_contains(command, "display-popup") then
      popup_command = command
      return 123
    end
    return original_jobstart(command, opts)
  end
  expect_target(second_pid)

  vim.fn.chansend(second, "\27[O")
  vim.fn.chansend(first, "\27[I")
  ark_test.wait_for("first client focused", 5000, function()
    local current = clients()
    return current[first_pid].flags:find("focused", 1, true) and not current[second_pid].flags:find("focused", 1, true)
  end)
  expect_target(first_pid)

  -- Without terminal focus reporting, recent input is the best available
  -- signal. tmux timestamps have second resolution, so cross a clock tick.
  vim.fn.chansend(first, "\27[O")
  local tick = os.time()
  ark_test.wait_for("next activity tick", 3000, function()
    return os.time() > tick
  end)
  vim.fn.chansend(second, "\r")
  ark_test.wait_for("recent second-client input", 5000, function()
    local activity = ark_test.tmux({ "display-message", "-p", "-c", clients()[second_pid].name, "#{client_activity}" })
    return tonumber(activity) > tick
  end)
  expect_target(second_pid)

  attach(true)
  expect_target(second_pid)
end, debug.traceback)

vim.fn.jobstart = original_jobstart
for _, job in ipairs(jobs) do
  pcall(vim.fn.jobstop, job)
end
for _, path in ipairs(vim.fn.glob("/tmp/ark-nvim-popup-" .. vim.fn.getpid() .. "-*", false, true)) do
  vim.fn.delete(path)
end
stop_watchdog()
if not ok then
  error(err, 0)
end
vim.print({ tmux_popup_active_client = "ok" })
