-- True interactive uncaught error -> supported bridge RPC -> asynchronous Lua.
local ark_test = require("ark_test")
local root = ark_test.run_tmpdir() .. "/error-traceback"
vim.fn.mkdir(root, "p")
local source = root .. "/failure.R"
local pane, client = ark_test.setup_managed_buffer(source, {
  "outer <- function() inner()",
  "inner <- function() stop('ark traceback e2e fixture')",
})
ark_test.tmux({
  "send-keys",
  "-t",
  pane,
  "source(" .. vim.json.encode(source) .. ", keep.source = TRUE); outer()",
  "Enter",
})
ark_test.wait_for("uncaught R error", 10000, function()
  return ark_test.tmux({ "capture-pane", "-p", "-t", pane }):find("ark traceback e2e fixture", 1, true) ~= nil
end)
ark_test.wait_for("R prompt after uncaught error", 10000, function()
  return require("ark").status().repl_ready == true
end)
dofile(vim.fn.getcwd() .. "/plugin/ark.lua")
local frames, select_frame
local old_select = vim.ui.select
vim.ui.select = function(items, _, on_select)
  frames, select_frame = items, on_select
end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local origin = vim.api.nvim_get_current_win()
local before = vim.uv.hrtime()
vim.cmd("Ark traceback")
assert((vim.uv.hrtime() - before) / 1e6 < 50, "traceback dispatch blocked the editor")
ark_test.wait_for("traceback picker", 10000, function()
  return frames ~= nil
end)
vim.ui.select = old_select
local found
for _, frame in ipairs(frames) do
  if frame.path == source and frame.line == 1 then
    found = frame
  end
end
assert(found, "genuine source references missing: " .. vim.inspect(frames))
select_frame(found)
ark_test.wait_for("traceback source navigation", 1000, function()
  return vim.api.nvim_get_current_win() == origin and vim.api.nvim_win_get_cursor(origin)[1] == 1
end)
-- Asking again must return the original stack, not Ark's inspection frames.
local again = ark_test.request(client, "ark/internal/errorTraceback", {}, 5000)
assert(vim.deep_equal(frames, again.frames), "inspection replaced R's error stack")
print("live uncaught error traceback command, RPC and source navigation: ok")
