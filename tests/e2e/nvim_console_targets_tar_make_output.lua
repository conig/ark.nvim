vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(45000, "nvim_console_targets_tar_make_output")

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for nvim_console_targets_tar_make_output")
end

local has_targets = vim.fn.system({ "Rscript", "-e", "cat(requireNamespace('targets', quietly = TRUE))" })
if vim.v.shell_error ~= 0 or has_targets:find("TRUE", 1, true) == nil then
  ark_test.fail("targets package is required for nvim_console_targets_tar_make_output")
end

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/real-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "exec R --quiet --no-save --no-restore",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local project = vim.fs.normalize(run_tmpdir .. "/targets-project")
vim.fn.mkdir(project, "p")
local targets_lines = {
  "list(",
}
for index = 1, 26 do
  local dependency = index == 1 and "1" or ("target_" .. tostring(index - 1) .. " + 1")
  local comma = index == 26 and "" or ","
  targets_lines[#targets_lines + 1] = string.format(
    "  targets::tar_target(target_%d, { Sys.sleep(0.15); %s })%s",
    index,
    dependency,
    comma
  )
end
targets_lines[#targets_lines + 1] = ")"
vim.fn.writefile(targets_lines, project .. "/_targets.R")

vim.cmd("cd " .. vim.fn.fnameescape(project))

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
  ark_test.fail("failed to start real R nvim console: " .. tostring(err))
end

ark_test.wait_for("real R top-level prompt", 15000, function()
  local status = require("ark.console").status(bufnr)
  return type(status) == "table" and status.running == true and status.prompt_state == "top-level"
end)

local status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, {
  [[targets::tar_make(); cat("ARK_TARGETS_DONE\n"); flush.console()]],
})
local ok, submit_err = require("ark.console").submit(bufnr)
if not ok then
  ark_test.fail("failed to submit targets tar_make probe: " .. tostring(submit_err))
end

local function active_prompt_text()
  local prompt_ns = vim.api.nvim_get_namespaces().ArkConsole
  if type(prompt_ns) ~= "number" then
    return ""
  end

  local chunks = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, prompt_ns, 0, -1, { details = true })) do
    local virt_text = type(mark[4]) == "table" and mark[4].virt_text or nil
    if type(virt_text) == "table" then
      for _, chunk in ipairs(virt_text) do
        if type(chunk) == "table" and type(chunk[1]) == "string" then
          chunks[#chunks + 1] = chunk[1]
        end
      end
    end
  end

  return table.concat(chunks, "")
end

-- Regression: during a real targets build, the live console prompt should show
-- the targets progress bar, not the generic busy "*".
local saw_targets_bar = vim.wait(15000, function()
  local prompt = active_prompt_text()
  return prompt:find("26 targets", 1, true) ~= nil
    and prompt:find("■", 1, true) ~= nil
    and prompt:find("%[") ~= nil
end, 100, false)
if not saw_targets_bar then
  ark_test.fail("targets tar_make progress bar was not visible while running: " .. vim.inspect({
    prompt = active_prompt_text(),
    status = require("ark.console").status(bufnr),
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
  }))
end

ark_test.wait_for("targets tar_make completion marker", 30000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> ARK_TARGETS_DONE", 1, true) ~= nil
end)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local transcript = table.concat(lines, "\n")
if not transcript:find("#> + target_1 dispatched", 1, true) then
  ark_test.fail("targets tar_make output lost '+ target_1 dispatched': " .. vim.inspect(lines))
end
if not transcript:find("#> + target_26 dispatched", 1, true) then
  ark_test.fail("targets tar_make output lost '+ target_26 dispatched': " .. vim.inspect(lines))
end
if transcript:find("#> target_1 dispatched", 1, true) or transcript:find("#> target_26 dispatched", 1, true) then
  ark_test.fail("targets tar_make output stripped dispatch markers: " .. vim.inspect(lines))
end

-- Regression: targets rewrites a live progress bar with carriage returns. Once
-- a dispatch/completion message is committed to the transcript, it must not
-- retain stale bytes from the previous progress-bar line.
for _, line in ipairs(lines) do
  if line:match("^#> [%+✔] ") then
    if line:find("26 targets", 1, true) or line:find("■", 1, true) or line:match("%[%d[%d%.]*s, %d+%+, %d+%-") then
      ark_test.fail("targets tar_make transcript line retained progress-bar tail: " .. vim.inspect({
        line = line,
        lines = lines,
      }))
    end
  end

  for index = 1, 26 do
    local dispatch = string.format("#> + target_%d dispatched", index)
    if line:sub(1, #dispatch) == dispatch and line ~= dispatch then
      ark_test.fail("targets tar_make dispatch line retained overwritten bytes: " .. vim.inspect({
        expected = dispatch,
        line = line,
        lines = lines,
      }))
    end

    local completion_prefix = string.format("#> ✔ target_%d completed [", index)
    if line:sub(1, #completion_prefix) == completion_prefix then
      local _, open_brackets = line:gsub("%[", "")
      local _, close_brackets = line:gsub("%]", "")
      if not line:match("^#> ✔ target_" .. tostring(index) .. " completed %[.-%]$")
        or open_brackets ~= 1
        or close_brackets ~= 1
      then
        ark_test.fail("targets tar_make completion line retained overwritten bytes: " .. vim.inspect({
          line = line,
          lines = lines,
        }))
      end
    end
  end

  if line:sub(1, #"#> ✔ ended pipeline [") == "#> ✔ ended pipeline [" then
    local _, open_brackets = line:gsub("%[", "")
    local _, close_brackets = line:gsub("%]", "")
    if not line:match("^#> ✔ ended pipeline %[.-%]$") or open_brackets ~= 1 or close_brackets ~= 1 then
      ark_test.fail("targets tar_make summary line retained overwritten bytes: " .. vim.inspect({
        line = line,
        lines = lines,
      }))
    end
  end
end

ark_test.wait_for("real R prompt after targets tar_make", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.running == true and current.prompt_state == "top-level"
end)

local stop_ok, stop_err = require("ark.console").stop(bufnr)
if not stop_ok then
  ark_test.fail("failed to stop real R console: " .. tostring(stop_err))
end

ark_test.wait_for("real R stopped after targets tar_make", 15000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.running == false
end)

stop_watchdog()
