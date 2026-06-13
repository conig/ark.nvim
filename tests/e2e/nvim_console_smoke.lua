vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_smoke")

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = vim.fs.normalize(run_tmpdir .. "/fake-r")
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf 'backend=%s session=%s status=%s\\n' \"$ARK_SESSION_BACKEND\" \"$ARK_SESSION_ID\" \"$ARK_SESSION_STATUS_FILE\"",
  "printf '> '",
  "while IFS= read -r line; do",
  "  if [[ \"$line\" == incomplete* ]]; then",
  "    printf '+ '",
  "  else",
  "    printf 'console saw: %s\\n' \"$line\"",
  "    printf '> '",
  "  fi",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  lsp = {
    cmd = { "/bin/cat" },
  },
  terminal = {
    launcher = launcher,
    startup_status_dir = vim.fs.normalize(run_tmpdir .. "/status"),
    session_pkg_path = vim.fs.normalize(run_tmpdir .. "/arkbridge"),
  },
})

local bufnr, err = ark.console()
if not bufnr then
  ark_test.fail("failed to start nvim console: " .. tostring(err))
end
if vim.b[bufnr].ark_console ~= true then
  ark_test.fail("console buffer did not mark vim.b.ark_console")
end
if vim.bo[bufnr].filetype ~= "r" then
  ark_test.fail("console buffer should be an R buffer, got " .. vim.bo[bufnr].filetype)
end

local lsp_config = ark.lsp_config(bufnr)
if type(lsp_config) ~= "table" or type(lsp_config.root_dir) ~= "string" then
  ark_test.fail("console buffer did not produce an LSP config with a root_dir: " .. vim.inspect(lsp_config))
end
if lsp_config.root_dir:find("ark%-console://") then
  ark_test.fail("console LSP root_dir should not use the virtual URI: " .. vim.inspect(lsp_config))
end

vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mtcars$mpg" })
local ok, submit_err = require("ark.console").submit(bufnr)
if not ok then
  ark_test.fail("failed to submit console input: " .. tostring(submit_err))
end

ark_test.wait_for("console transcript output", 10000, function()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(lines, "\n"):find("#> console saw: mtcars%$mpg") ~= nil
end)

local status = require("ark.console").status(bufnr)
if type(status) ~= "table" or status.running ~= true or type(status.session_id) ~= "string" then
  ark_test.fail("unexpected console status: " .. vim.inspect(status))
end
if type(status.status_path) ~= "string" or not status.status_path:find(status.session_id, 1, true) then
  ark_test.fail("console status should expose session status file: " .. vim.inspect(status))
end
if type(status.rpc_socket) ~= "string" or status.rpc_socket == "" then
  ark_test.fail("console status should expose an RPC socket: " .. vim.inspect(status))
end
if status.prompt_state ~= "top-level" then
  ark_test.fail("console should return to top-level after complete input: " .. vim.inspect(status))
end

ark_test.wait_for("console published RPC socket in status file", 10000, function()
  local published = require("ark.session_runtime").read_status_file(status.status_path)
  return type(published) == "table" and published.nvim_console_rpc_socket == status.rpc_socket
end)

local chan = vim.fn.sockconnect("pipe", status.rpc_socket, { rpc = true })
if type(chan) ~= "number" or chan <= 0 then
  ark_test.fail("failed to connect to console RPC socket: " .. vim.inspect(status))
end
local rpc_ok, rpc_err = pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return _G.__ark_console_rpc_send(...)", {
  "rpc_call()",
})
pcall(vim.fn.chanclose, chan)
if not rpc_ok then
  ark_test.fail("console RPC send failed: " .. tostring(rpc_err))
end

ark_test.wait_for("console RPC transcript output", 10000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> console saw: rpc_call%(%)") ~= nil
end)

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
if lines[1] ~= "mtcars$mpg" then
  ark_test.fail("submitted input should remain as R code: " .. vim.inspect(lines))
end
if not vim.tbl_contains(lines, "#> console saw: mtcars$mpg") then
  ark_test.fail("console output should be recorded as R comments: " .. vim.inspect(lines))
end
local transcript = table.concat(lines, "\n")
if not transcript:find("#> backend=nvim%-console session=", 1, false) then
  ark_test.fail("console child did not receive Ark session env: " .. vim.inspect(lines))
end
if transcript:find("^#> >") or transcript:find("^#> %+", 1, false) then
  ark_test.fail("console prompts should be suppressed from transcript: " .. vim.inspect(lines))
end

local shifted_status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "# user note above active input" })
local shifted_after_insert = require("ark.console").status(bufnr)
if shifted_after_insert.input_start ~= shifted_status.input_start + 1 then
  ark_test.fail("console input boundary should track edits above it: before="
    .. vim.inspect(shifted_status)
    .. " after="
    .. vim.inspect(shifted_after_insert))
end
vim.api.nvim_buf_set_lines(bufnr, shifted_after_insert.input_start, -1, false, { "after_shift()" })
local shifted_ok, shifted_err = require("ark.console").submit(bufnr)
if not shifted_ok then
  ark_test.fail("failed to submit shifted console input: " .. tostring(shifted_err))
end
ark_test.wait_for("console shifted-boundary transcript output", 10000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> console saw: after_shift%(%)") ~= nil
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "draft_call()" })
local prev_ok, prev_err = require("ark.console").history_prev(bufnr)
if not prev_ok then
  ark_test.fail("failed to navigate to previous console history item: " .. tostring(prev_err))
end
local history_prev_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_prev_lines, "\n") ~= "after_shift()" then
  ark_test.fail("previous history should restore submitted R code: " .. vim.inspect(history_prev_lines))
end

prev_ok, prev_err = require("ark.console").history_prev(bufnr)
if not prev_ok then
  ark_test.fail("failed to navigate to older console history item: " .. tostring(prev_err))
end
history_prev_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_prev_lines, "\n") ~= "rpc_call()" then
  ark_test.fail("second previous history should restore newer remote R code: " .. vim.inspect(history_prev_lines))
end

prev_ok, prev_err = require("ark.console").history_prev(bufnr)
if not prev_ok then
  ark_test.fail("failed to navigate to oldest console history item: " .. tostring(prev_err))
end
history_prev_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_prev_lines, "\n") ~= "mtcars$mpg" then
  ark_test.fail("third previous history should restore oldest R code: " .. vim.inspect(history_prev_lines))
end

local next_ok, next_err = require("ark.console").history_next(bufnr)
if not next_ok then
  ark_test.fail("failed to navigate to next console history item: " .. tostring(next_err))
end
local history_next_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_next_lines, "\n") ~= "rpc_call()" then
  ark_test.fail("next history should restore newer R code: " .. vim.inspect(history_next_lines))
end

next_ok, next_err = require("ark.console").history_next(bufnr)
if not next_ok then
  ark_test.fail("failed to navigate to newest console history item: " .. tostring(next_err))
end
history_next_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_next_lines, "\n") ~= "after_shift()" then
  ark_test.fail("second next history should restore newest R code: " .. vim.inspect(history_next_lines))
end

next_ok, next_err = require("ark.console").history_next(bufnr)
if not next_ok then
  ark_test.fail("failed to leave console history: " .. tostring(next_err))
end
history_next_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_next_lines, "\n") ~= "draft_call()" then
  ark_test.fail("leaving history should restore the active draft input: " .. vim.inspect(history_next_lines))
end

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "multi_one()multi_two()" })
vim.api.nvim_win_set_cursor(0, { status.input_start + 1, #"multi_one()" })
local newline_ok, newline_err = require("ark.console").insert_newline(bufnr)
if not newline_ok then
  ark_test.fail("failed to insert newline in console input: " .. tostring(newline_err))
end
local split_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if vim.inspect(split_lines) ~= vim.inspect({ "multi_one()", "multi_two()" }) then
  ark_test.fail("insert_newline should split the current input line: " .. vim.inspect(split_lines))
end
local split_ok, split_err = require("ark.console").submit(bufnr)
if not split_ok then
  ark_test.fail("failed to submit split console input: " .. tostring(split_err))
end
ark_test.wait_for("split input first output", 10000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> console saw: multi_one%(%)") ~= nil
end)
ark_test.wait_for("split input second output", 10000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> console saw: multi_two%(%)") ~= nil
end)

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "incomplete" })
local incomplete_ok, incomplete_err = require("ark.console").submit(bufnr)
if not incomplete_ok then
  ark_test.fail("failed to submit incomplete console input: " .. tostring(incomplete_err))
end
ark_test.wait_for("continuation prompt state", 10000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "continuation"
end)

local continuation_status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, continuation_status.input_start, -1, false, { "complete_after_incomplete()" })
local continuation_ok, continuation_err = require("ark.console").submit(bufnr)
if not continuation_ok then
  ark_test.fail("failed to submit console continuation input: " .. tostring(continuation_err))
end
ark_test.wait_for("continuation completion output", 10000, function()
  local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return table.concat(current_lines, "\n"):find("#> console saw: complete_after_incomplete%(%)") ~= nil
end)

local continuation_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local continuation_transcript = table.concat(continuation_lines, "\n")
if not continuation_transcript:find("\nincomplete\n", 1, true) then
  ark_test.fail("incomplete continuation input should remain as R code: " .. vim.inspect(continuation_lines))
end
if not continuation_transcript:find("\ncomplete_after_incomplete()\n", 1, true) then
  ark_test.fail("completed continuation input should remain as R code: " .. vim.inspect(continuation_lines))
end

stop_watchdog()
