local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(60000, "ark_help_rma_mv_timing")

local function monotonic_ms()
  return math.floor(vim.uv.hrtime() / 1e6)
end

local unpack_result = table.unpack or unpack

local test_file = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_help_rma_mv_timing.R")
local pane_id = ark_test.setup_managed_buffer(test_file, {
  "metafor::rma.mv(",
}, {
  help = {
    display = "float",
  },
  tmux = {
    session_lib_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/r-lib"),
  },
})

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'ark_metafor_available <- requireNamespace("metafor", quietly = TRUE)',
  "Enter",
  "ark_metafor_available",
  "Enter",
})

ark_test.wait_for("metafor availability probe", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil
end)

local has_metafor = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id }):find("%[1%] TRUE") ~= nil
if not has_metafor then
  stop_watchdog()
  ark_test.fail("metafor is required for ArkHelp rma.mv timing coverage")
end

ark_test.wait_for("detached session ready", 15000, function()
  local status = require("ark").status({ include_lsp = true })
  local lsp_status = type(status) == "table" and status.lsp_status or nil
  local detached = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil
  return type(lsp_status) == "table"
    and lsp_status.available == true
    and lsp_status.sessionBridgeConfigured == true
    and type(detached) == "table"
    and detached.lastSessionUpdateStatus == "ready"
end)

vim.api.nvim_win_set_cursor(0, { 1, 12 })
dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))

local timings = {}
local lsp = require("ark.lsp")
local session = require("ark.session")
local original_help_topic = lsp.help_topic
local original_help_text = lsp.help_text
local original_sync_sessions = lsp.sync_sessions
local original_session_start = session.start
local original_session_status = session.status

local function time_call(key, fn, ...)
  local call_started = monotonic_ms()
  local result = { fn(...) }
  timings[key] = (timings[key] or 0) + (monotonic_ms() - call_started)
  return unpack_result(result)
end

lsp.help_topic = function(...)
  return time_call("help_topic_ms", original_help_topic, ...)
end

lsp.help_text = function(...)
  return time_call("help_text_ms", original_help_text, ...)
end

lsp.sync_sessions = function(...)
  return time_call("sync_sessions_ms", original_sync_sessions, ...)
end

session.start = function(...)
  return time_call("session_start_ms", original_session_start, ...)
end

session.status = function(...)
  return time_call("session_status_ms", original_session_status, ...)
end

local started = monotonic_ms()
vim.cmd("ArkHelp")
local elapsed_ms = monotonic_ms() - started

lsp.help_topic = original_help_topic
lsp.help_text = original_help_text
lsp.sync_sessions = original_sync_sessions
session.start = original_session_start
session.status = original_session_status

local help_buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(help_buf, 0, math.min(30, vim.api.nvim_buf_line_count(help_buf)), false)
local text = table.concat(lines, "\n")
if vim.bo[help_buf].filetype ~= "markdown" then
  stop_watchdog()
  ark_test.fail("expected ArkHelp to open a markdown buffer, got " .. tostring(vim.bo[help_buf].filetype))
end
if not text:find("rma%.mv", 1) then
  stop_watchdog()
  ark_test.fail("expected rma.mv documentation, got " .. vim.inspect(lines))
end

-- Baseline before the render fast path was 538 ms on this path.
local max_ms = tonumber(vim.env.ARK_HELP_RMA_MV_MAX_MS or "269")
if max_ms and elapsed_ms > max_ms then
  stop_watchdog()
  ark_test.fail("ArkHelp rma.mv took " .. tostring(elapsed_ms) .. "ms, expected <= " .. tostring(max_ms) .. "ms")
end

vim.print({
  ark_help_rma_mv_elapsed_ms = elapsed_ms,
  phases = timings,
  title = lines[1],
})

stop_watchdog()
