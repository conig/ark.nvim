vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_busy_spinner")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r-busy")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '> '",
  "while IFS= read -r line; do",
  "  if [ \"$line\" = slow ]; then",
  "    sleep 5",
  "    printf 'analysis complete\\n> '",
  "  elif [ \"$line\" = 'slow_block <- {' ]; then",
  "    printf '+ '",
  "  elif [ \"$line\" = '  slow' ]; then",
  "    sleep 5",
  "    printf '+ '",
  "  elif [ \"$line\" = '}' ]; then",
  "    printf 'analysis complete\\n> '",
  "  else",
  "    printf 'saw: %s\\n> ' \"$line\"",
  "  fi",
  "done",
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
  ark_test.fail("failed to start busy spinner console: " .. tostring(err))
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

ark_test.wait_for("fake busy console prompt", 10000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

-- Let the launcher's initial prompt drain before submitting the probe.
vim.wait(500, function()
  return false
end, 25, false)

local status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "slow" })
local submit_ok, submit_err = require("ark.console").submit(bufnr)
if not submit_ok then
  ark_test.fail("failed to submit busy spinner probe: " .. tostring(submit_err))
end

ark_test.wait_for("busy spinner state", 5000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "busy"
end)

local published = require("ark.session_runtime").read_status_file(require("ark.console").status(bufnr).status_path)
assert(published.nvim_console_prompt_state == "busy", "submission must publish busy before waiting for R")

local delayed_text, delayed_group = active_prompt()
if delayed_text ~= "* " or delayed_group ~= "ArkConsolePrompt" then
  ark_test.fail("busy prompt should stay static during the spinner grace period: " .. vim.inspect({
    text = delayed_text,
    group = delayed_group,
  }))
end

local first_text, first_group = delayed_text, delayed_group
local activated = vim.wait(1500, function()
  first_text, first_group = active_prompt()
  return first_group:match("^ArkConsoleBusy%d+$") ~= nil
end, 25, false)
if not activated or first_text ~= "⠋ " then
  ark_test.fail("busy prompt should activate the first rainbow spinner frame after its delay: " .. vim.inspect({
    text = first_text,
    group = first_group,
  }))
end

local changed_text, changed_group = first_text, first_group
local changed = vim.wait(1000, function()
  changed_text, changed_group = active_prompt()
  return changed_text ~= first_text and changed_group ~= first_group
end, 25, false)
if not changed then
  ark_test.fail("busy spinner did not advance to a new rainbow frame: " .. vim.inspect({
    text = changed_text,
    group = changed_group,
  }))
end

local first_hl = vim.api.nvim_get_hl(0, { name = first_group, link = false })
local changed_hl = vim.api.nvim_get_hl(0, { name = changed_group, link = false })
if type(first_hl.fg) ~= "number" or type(changed_hl.fg) ~= "number" or first_hl.fg == changed_hl.fg then
  ark_test.fail("busy spinner frames should use different rainbow highlight colors: " .. vim.inspect({
    first = first_hl,
    changed = changed_hl,
  }))
end

ark_test.wait_for("fake analysis completion", 10000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "top-level"
end)

published = require("ark.session_runtime").read_status_file(require("ark.console").status(bufnr).status_path)
assert(published.nvim_console_prompt_state == "top-level", "returning prompt must clear published busy state")

local done_text, done_group = active_prompt()
if done_text ~= "> " or done_group ~= "ArkConsolePrompt" then
  ark_test.fail("busy spinner should be replaced by the normal prompt after R returns: " .. vim.inspect({
    text = done_text,
    group = done_group,
  }))
end

local stable = vim.wait(700, function()
  local current_text, current_group = active_prompt()
  return current_text ~= done_text or current_group ~= done_group
end, 25, false)
if stable then
  ark_test.fail("busy spinner continued animating after R returned: " .. vim.inspect(active_prompt()))
end

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, {
  "slow_block <- {",
  "  slow",
  "}",
})
submit_ok, submit_err = require("ark.console").submit(bufnr)
if not submit_ok then
  ark_test.fail("failed to submit multiline busy spinner probe: " .. tostring(submit_err))
end

ark_test.wait_for("multiline busy spinner state", 5000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "busy"
end)

local multiline_prompt, multiline_group = active_prompt()
if multiline_prompt ~= "* " or multiline_group ~= "ArkConsolePrompt" then
  ark_test.fail("multiline busy prompt should stay static during the spinner grace period: " .. vim.inspect({
    text = multiline_prompt,
    group = multiline_group,
  }))
end

local multiline_activated = vim.wait(1500, function()
  multiline_prompt, multiline_group = active_prompt()
  return multiline_group:match("^ArkConsoleBusy%d+$") ~= nil
end, 25, false)
local saw_intermediate_continuation = vim.wait(1000, function()
  local current_prompt = active_prompt()
  return current_prompt == "+ "
end, 25, false)
if not multiline_activated or saw_intermediate_continuation or multiline_prompt == "+ " then
  ark_test.fail("intermediate R continuation prompt should not replace the busy spinner: " .. vim.inspect({
    text = multiline_prompt,
    group = multiline_group,
    saw_intermediate_continuation = saw_intermediate_continuation,
  }))
end

ark_test.wait_for("multiline fake analysis completion", 10000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "top-level"
end)

stop_watchdog()
