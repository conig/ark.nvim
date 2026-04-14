local ark_test = require("ark_test")

local test_file = "/tmp/ark_launcher_status_skips_install_phases.R"
local pane_id = ark_test.setup_managed_buffer(test_file, {
  "x <- 1",
})

local status = require("ark").status({ include_lsp = true })
local startup_status = status.startup_status or {}
local log_path = startup_status.log_path
if type(log_path) ~= "string" or log_path == "" then
  error("missing launcher log path in startup status: " .. vim.inspect(status), 0)
end

ark_test.wait_for("launcher log file", 5000, function()
  return vim.fn.filereadable(log_path) == 1
end)

local log_text = table.concat(vim.fn.readfile(log_path), "\n")

for _, phase in ipairs({ "check_install", "installing", "install_done", "up_to_date" }) do
  if log_text:find("phase=" .. phase, 1, true) ~= nil then
    error("launcher unexpectedly performed install-phase startup work: " .. vim.inspect({
      phase = phase,
      log_path = log_path,
      pane_id = pane_id,
      log = log_text,
    }), 0)
  end
end

if log_text:find("phase=runtime_check", 1, true) == nil or log_text:find("phase=start_service", 1, true) == nil then
  error("launcher log is missing expected runtime-only phases: " .. vim.inspect({
    log_path = log_path,
    pane_id = pane_id,
    log = log_text,
  }), 0)
end

vim.print({
  log_path = log_path,
  pane_id = pane_id,
  log = log_text,
})
