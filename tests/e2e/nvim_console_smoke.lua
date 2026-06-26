vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

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

local winid = vim.fn.bufwinid(bufnr)
if type(winid) == "number" and winid > 0 then
  vim.api.nvim_set_current_win(winid)
end

local view_calls = {}
local target_view_calls = {}
local real_view_under_cursor = ark.view_under_cursor
local real_targets_view_pick = ark.targets_view_pick
ark.view_under_cursor = function(view_bufnr)
  view_calls[#view_calls + 1] = view_bufnr
end
ark.targets_view_pick = function(view_bufnr)
  target_view_calls[#target_view_calls + 1] = view_bufnr
end

local view_map = vim.fn.maparg("<leader>rv", "n", false, true)
if type(view_map) ~= "table" or type(view_map.callback) ~= "function" then
  ark_test.fail("console should map normal <leader>rv to ArkView: " .. vim.inspect(view_map))
end

local visual_view_map = vim.fn.maparg("<leader>rv", "x", false, true)
if type(visual_view_map) ~= "table" or type(visual_view_map.callback) ~= "function" then
  ark_test.fail("console should map visual <leader>rv to ArkView: " .. vim.inspect(visual_view_map))
end

local upper_view_map = vim.fn.maparg("<leader>rV", "n", false, true)
if type(upper_view_map) ~= "table" or type(upper_view_map.callback) ~= "function" then
  ark_test.fail("console should map normal <leader>rV to ArkView: " .. vim.inspect(upper_view_map))
end

local visual_upper_view_map = vim.fn.maparg("<leader>rV", "x", false, true)
if type(visual_upper_view_map) ~= "table" or type(visual_upper_view_map.callback) ~= "function" then
  ark_test.fail("console should map visual <leader>rV to ArkView: " .. vim.inspect(visual_upper_view_map))
end

local target_view_map = vim.fn.maparg("<leader>tv", "n", false, true)
if type(target_view_map) ~= "table" or type(target_view_map.callback) ~= "function" then
  ark_test.fail("console should map normal <leader>tv to target ArkView: " .. vim.inspect(target_view_map))
end

view_map.callback()
upper_view_map.callback()
if view_calls[1] ~= bufnr or view_calls[2] ~= bufnr then
  ark_test.fail("console ArkView mappings should target the console buffer, got " .. vim.inspect(view_calls))
end

target_view_map.callback()
if target_view_calls[1] ~= bufnr then
  ark_test.fail("console <leader>tv should target the console buffer, got " .. vim.inspect(target_view_calls))
end

ark.view_under_cursor = real_view_under_cursor
ark.targets_view_pick = real_targets_view_pick

local real_view_open_exprs = {}
local real_view_open_bufnrs = {}
local backend_start_calls = {}
local lsp = require("ark.lsp")
local tmux = require("ark.tmux")
lsp.start = function()
  return bufnr
end
lsp.sync_sessions = function() end
lsp.status = function()
  return {
    available = true,
    sessionBridgeConfigured = true,
    detachedSessionStatus = {
      lastSessionUpdateStatus = "ready",
    },
  }
end
lsp.view_open = function(_opts, view_bufnr, expr)
  real_view_open_bufnrs[#real_view_open_bufnrs + 1] = view_bufnr
  real_view_open_exprs[#real_view_open_exprs + 1] = expr
  return {
    session_id = "console-keymap-view",
    title = expr,
    total_rows = 1,
    total_columns = 1,
    schema = {
      { index = 1, name = "x", class = "numeric", type = "double" },
    },
    filters = {},
    sort = { column_index = 0, direction = "" },
  }, nil
end
lsp.view_page = function()
  return {
    offset = 0,
    limit = 100,
    total_rows = 1,
    row_numbers = { 1 },
    rows = {
      { "1" },
    },
  }, nil
end
lsp.view_state = function()
  return {
    session_id = "console-keymap-view",
    title = "mtcars",
    total_rows = 1,
    total_columns = 1,
    schema = {
      { index = 1, name = "x", class = "numeric", type = "double" },
    },
    filters = {},
    sort = { column_index = 0, direction = "" },
  }, nil
end
tmux.status = function()
  return {
    bridge_ready = true,
    repl_ready = true,
  }
end
tmux.start = function(...)
  backend_start_calls[#backend_start_calls + 1] = { ... }
  return "%unexpected", nil
end

-- Regression: ArkView from an nvim-console input should work even when the
-- console was opened without a separate remembered R source buffer. It should
-- use the console's own session instead of starting a second managed backend.
vim.api.nvim_set_current_win(winid)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "mtcars" })
vim.api.nvim_win_set_cursor(0, { 1, 2 })
vim.cmd("stopinsert")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>rV", true, false, true), "xt", false)
local console_keypress_opened_view = vim.wait(1000, function()
  return real_view_open_exprs[1] ~= nil
end, 20, false)
if not console_keypress_opened_view then
  ark_test.fail("console normal-mode <leader>rV should open ArkView, got no view requests")
end
if real_view_open_exprs[1] ~= "mtcars" or real_view_open_bufnrs[1] ~= bufnr then
  ark_test.fail("console normal-mode <leader>rV should view mtcars from the console buffer, got " .. vim.inspect({
    exprs = real_view_open_exprs,
    bufnrs = real_view_open_bufnrs,
    console_bufnr = bufnr,
  }))
end
if #backend_start_calls ~= 0 then
  ark_test.fail("console normal-mode <leader>rV should not start a separate backend: " .. vim.inspect(backend_start_calls))
end
ark.view_close()
if vim.api.nvim_win_is_valid(winid) then
  vim.api.nvim_set_current_win(winid)
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

ark_test.wait_for("console top-level prompt after initial input", 10000, function()
  local current = require("ark.console").status(bufnr)
  return type(current) == "table" and current.prompt_state == "top-level"
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
local namespaces = vim.api.nvim_get_namespaces()
local transcript_prompt_ns = namespaces.ArkConsoleTranscriptPrompt
local transcript_prompt_marks = type(transcript_prompt_ns) == "number"
    and vim.api.nvim_buf_get_extmarks(bufnr, transcript_prompt_ns, 0, -1, { details = true })
  or {}
local saw_submitted_prompt = false
for _, mark in ipairs(transcript_prompt_marks) do
  if mark[2] == 0 then
    local details = mark[4]
    local chunk = type(details) == "table" and type(details.virt_text) == "table" and details.virt_text[1] or nil
    if type(chunk) == "table" and chunk[1] == "> " then
      saw_submitted_prompt = true
      break
    end
  end
end
if not saw_submitted_prompt then
  ark_test.fail("submitted input should render with an R console prompt extmark: " .. vim.inspect(transcript_prompt_marks))
end
if not vim.tbl_contains(lines, "#> console saw: mtcars$mpg") then
  ark_test.fail("console output should be recorded as R comments: " .. vim.inspect(lines))
end
local transcript = table.concat(lines, "\n")
if not transcript:find("#> backend=[^ ]+ session=[^ ]+ status=[^\n]+") then
  ark_test.fail("console child did not receive Ark session env: " .. vim.inspect(lines))
end
if transcript:find("^#> >") or transcript:find("^#> %+", 1, false) then
  ark_test.fail("console prompts should be suppressed from transcript: " .. vim.inspect(lines))
end

status = require("ark.console").status(bufnr)
vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { "draft_call()" })
local prev_ok, prev_err = require("ark.console").history_prev(bufnr)
if not prev_ok then
  ark_test.fail("failed to navigate to previous console history item: " .. tostring(prev_err))
end
local history_prev_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_prev_lines, "\n") ~= "rpc_call()" then
  ark_test.fail("previous history should restore submitted R code: " .. vim.inspect(history_prev_lines))
end

prev_ok, prev_err = require("ark.console").history_prev(bufnr)
if not prev_ok then
  ark_test.fail("failed to navigate to older console history item: " .. tostring(prev_err))
end
history_prev_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_prev_lines, "\n") ~= "mtcars$mpg" then
  ark_test.fail("second previous history should restore oldest R code: " .. vim.inspect(history_prev_lines))
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
if table.concat(history_next_lines, "\n") ~= "draft_call()" then
  ark_test.fail("second next history should restore the active draft input: " .. vim.inspect(history_next_lines))
end

next_ok, next_err = require("ark.console").history_next(bufnr)
if not next_ok then
  ark_test.fail("failed to leave console history: " .. tostring(next_err))
end
history_next_lines = vim.api.nvim_buf_get_lines(bufnr, status.input_start, -1, false)
if table.concat(history_next_lines, "\n") ~= "draft_call()" then
  ark_test.fail("staying past newest history should keep the active draft input: " .. vim.inspect(history_next_lines))
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
