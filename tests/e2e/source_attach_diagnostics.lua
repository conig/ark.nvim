local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local function diagnostic_messages()
  local messages = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    messages[#messages + 1] = diagnostic.message
  end
  table.sort(messages)
  return messages
end

local function contains(messages, needle)
  for _, message in ipairs(messages) do
    if message == needle then
      return true
    end
  end
  return false
end

-- Regression scenario: a helper script attaches a package via source() in the
-- managed tmux R session, and diagnostics should reflect that new search-path
-- scope without requiring :ArkRefresh.
require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local controller_file = "/tmp/ark_source_attach_controller.R"
local test_file = "/tmp/ark_source_attach_diagnostics.R"
local diagnostic_message = "No symbol named 'tar_map' in scope."

vim.fn.writefile({
  "library(tarchetypes)",
}, controller_file)

vim.fn.writefile({
  string.format('source("%s")', controller_file),
  "tar_map()",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(0)

ark_test.wait_for("initial static lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

ark_test.wait_for("initial tar_map diagnostic", 10000, function()
  return contains(diagnostic_messages(), diagnostic_message)
end)

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  ark_test.fail(pane_err or "managed pane id missing")
end

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'if ("package:tarchetypes" %in% search()) detach("package:tarchetypes", unload = TRUE, character.only = TRUE); ark_tar_map_pre_source <- "package:tarchetypes" %in% search() || exists("tar_map")',
  "Enter",
  "ark_tar_map_pre_source",
  "Enter",
})

ark_test.wait_for("clean pre-source session", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] FALSE") ~= nil
end)

ark_test.wait_for("stale tar_map diagnostic before source", 5000, function()
  return contains(diagnostic_messages(), diagnostic_message)
end)

local source_cmd = string.format(
  'source("%s"); ark_tar_map_source_loaded <- "package:tarchetypes" %%in%% search() && exists("tar_map")',
  controller_file
)

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  source_cmd,
  "Enter",
  "ark_tar_map_source_loaded",
  "Enter",
})

ark_test.wait_for("tarchetypes source attach", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil
end)

local diagnostics_cleared = vim.wait(5000, function()
  return not contains(diagnostic_messages(), diagnostic_message)
end, 100, false)

local final_messages = diagnostic_messages()
local pane_capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })

if not diagnostics_cleared then
  ark_test.fail(vim.inspect({
    diagnostics = final_messages,
    pane_capture = pane_capture,
    status = require("ark").status(),
  }))
end

print(vim.json.encode({
  diagnostics = final_messages,
  pane_capture = pane_capture,
  status = require("ark").status(),
}))
