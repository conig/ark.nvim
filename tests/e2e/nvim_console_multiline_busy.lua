vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_multiline_busy")

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_multiline_busy")
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/real-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "exec R --quiet --no-save --no-restore",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start multiline busy console: " .. tostring(err))
end

local prompt_ns = vim.api.nvim_get_namespaces().ArkConsole
local function active_prompt()
  local status = require("ark.console").status(bufnr)
  if type(status) ~= "table" then
    return "", ""
  end

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, prompt_ns, 0, -1, { details = true })) do
    if mark[2] == status.input_start then
      local details = mark[4]
      local chunks = type(details) == "table" and details.virt_text or nil
      local text = {}
      local groups = {}
      for _, chunk in ipairs(chunks or {}) do
        if type(chunk) == "table" then
          text[#text + 1] = tostring(chunk[1] or "")
          groups[#groups + 1] = tostring(chunk[2] or "")
        end
      end
      return table.concat(text), table.concat(groups, ",")
    end
  end

  return "", ""
end

ark_test.wait_for("real R top-level prompt", 15000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

local expression = {
  "result <- mean(replicate(100, {",
  "  Sys.sleep(0.03)",
  "  1",
  "}))",
  "result",
}
local send_ok, send_err = require("ark.console").send_text(bufnr, table.concat(expression, "\n"))
if not send_ok then
  ark_test.fail("failed to send multiline busy expression: " .. tostring(send_err))
end

ark_test.wait_for("multiline R busy state", 5000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "busy"
end)

local initial_prompt, initial_group = active_prompt()
if initial_prompt ~= "* " or initial_group ~= "ArkConsolePrompt" then
  ark_test.fail("real R busy prompt should stay static during the spinner grace period: " .. vim.inspect({
    prompt = initial_prompt,
    group = initial_group,
  }))
end

local saw_continuation = vim.wait(1000, function()
  local prompt = active_prompt()
  return prompt == "+ "
end, 25, false)
if saw_continuation then
  ark_test.fail("intermediate R continuation prompt replaced the busy spinner: " .. vim.inspect({
    prompt = active_prompt(),
    status = require("ark.console").status(bufnr),
  }))
end

ark_test.wait_for("delayed real spinner", 3000, function()
  local _, current_group = active_prompt()
  return type(current_group) == "string" and current_group:match("^ArkConsoleBusy%d+$") ~= nil
end)

local prompt, group = active_prompt()
if prompt == "" or prompt == "+ " or not group:match("^ArkConsoleBusy%d+$") then
  ark_test.fail("multiline computation should keep the rainbow busy spinner active: " .. vim.inspect({
    prompt = prompt,
    group = group,
  }))
end

-- Exercise the real R process boundary: a busy marker that never advances is
-- indistinguishable from a hung submission in the user-facing console.
local advanced_prompt, advanced_group = prompt, group
local advanced = vim.wait(1500, function()
  advanced_prompt, advanced_group = active_prompt()
  return advanced_prompt ~= prompt or advanced_group ~= group
end, 25, false)
if not advanced then
  ark_test.fail("multiline busy spinner did not advance while real R was computing: " .. vim.inspect({
    initial_prompt = prompt,
    initial_group = group,
    current_prompt = advanced_prompt,
    current_group = advanced_group,
  }))
end

ark_test.wait_for("multiline R completion", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table"
    and current.prompt_state == "top-level"
    and table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"):find("#> result", 1, true) ~= nil
end)

stop_watchdog()
