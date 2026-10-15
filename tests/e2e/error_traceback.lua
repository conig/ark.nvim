-- Exercise the async UI boundary without needing an active R session.
vim.opt.rtp:prepend(vim.fn.getcwd())
local traceback = require("ark.traceback")
local selected, select_options, choose
local original_select, original_notify = vim.ui.select, vim.notify
local notices = {}
vim.ui.select = function(items, opts, callback)
  selected, select_options, choose = items, opts, callback
end
vim.notify = function(message)
  notices[#notices + 1] = message
end
local source = vim.fn.tempname() .. " | no-ex-command.R"
vim.fn.writefile({ "outer <- function() inner()", "inner <- function() stop('failed')" }, source)
local origin = vim.api.nvim_get_current_win()
local callback
local cancelled = 0
local started_at = vim.uv.hrtime()
assert(traceback.open(function(done)
  callback = done
  return true, nil, function()
    cancelled = cancelled + 1
  end
end))
assert((vim.uv.hrtime() - started_at) / 1e6 < 50, "opening traceback must not wait for R")
assert(selected == nil, "picker must wait for the asynchronous response")
local late = callback
traceback.open(function(done)
  callback = done
  return true, nil, function()
    cancelled = cancelled + 1
  end
end)
assert(cancelled == 1)
late({ status = "ok", available = true, frames = { { call = "stale()" } } })
vim.wait(30, function()
  return false
end)
assert(selected == nil, "cancelled replies must not open a picker")
callback({
  status = "ok",
  available = true,
  source = "last_uncaught_error",
  frames = {
    { index = 2, call = "inner()", path = source, line = 2 },
    { index = 1, call = "outer()" },
  },
})
assert(vim.wait(1000, function()
  return selected ~= nil
end))
assert(select_options.format_item(selected[2]):find("no source location", 1, true))
local before = vim.api.nvim_get_current_buf()
choose(selected[2])
assert(vim.api.nvim_get_current_buf() == before, "frames without srcrefs must not navigate")
choose(selected[1])
assert(vim.wait(1000, function()
  return vim.api.nvim_buf_get_name(0) == source
end))
assert(vim.api.nvim_get_current_win() == origin)
assert(vim.api.nvim_win_get_cursor(origin)[1] == 2)
selected = nil
traceback.open(function(done)
  done({ status = "ok", available = false, frames = {} })
  return true
end)
vim.wait(30, function()
  return false
end)
assert(selected == nil)
assert(notices[#notices]:find("No uncaught error", 1, true))
traceback.open(function()
  return nil, "dispatch fixture failed"
end)
vim.wait(30, function()
  return false
end)
assert(notices[#notices]:find("dispatch fixture failed", 1, true))
-- Saved-target inspection must remain asynchronous even with no workspace.
local complete, result, err
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
assert(traceback.target_request({ root = root, store = root .. "/_targets" }, "absent", function(payload, request_err)
  complete, result, err = true, payload, request_err
end))
assert(not complete)
assert(vim.wait(15000, function()
  return complete
end, 10))
assert(not err, tostring(err))
assert(result.status == "ok" and result.available == false, vim.inspect(result))
assert(result.message:find("No saved workspace", 1, true))
local fixture = vim
  .system({
    vim.env.ARK_NVIM_R_BIN or "R",
    "--slave",
    "--vanilla",
    "-f",
    vim.fn.getcwd() .. "/tests/e2e/target_traceback_worker.R",
    "--args",
    vim.fn.getcwd(),
  }, { text = true })
  :wait(30000)
assert(fixture.code == 0, fixture.stderr or fixture.stdout)
traceback.cancel()
vim.ui.select, vim.notify = original_select, original_notify
vim.fn.delete(source)
vim.fn.delete(root, "rf")
print("error traceback async UI and saved workspace contract: ok")
vim.cmd("qa!")
