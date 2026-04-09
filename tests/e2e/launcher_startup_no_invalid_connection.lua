local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

local test_file = "/tmp/ark_launcher_startup_no_invalid_connection.R"
local pane_id = ark_test.setup_managed_buffer(test_file, {
  "x <- 1",
})

ark_test.wait_for("launcher prompt settles", 5000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("R version", 1, true) ~= nil
end)

local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })

if capture:find("invalid connection", 1, true) ~= nil then
  fail("launcher printed invalid connection on startup: " .. vim.inspect({
    pane_capture = capture,
    status = require("ark").status({ include_lsp = true }),
  }))
end

vim.print({
  pane_capture = capture,
  status = require("ark").status({ include_lsp = true }),
})
