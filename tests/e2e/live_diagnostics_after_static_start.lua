local ark_test = require("ark_test")

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

local function completion_labels(result)
  local items = ark_test.completion_items(result)
  return ark_test.item_labels(items)
end

-- Ecologically valid startup flow:
-- 1. syntax diagnostics may appear before the managed R session exists
-- 2. semantic "unknown symbol" linting must wait until detached hydration is ready
-- 3. the user starts the managed pane
-- 4. the user keeps editing
-- 5. visible diagnostics should reflect the live session after hydration
require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_live_diagnostics_after_static_start.R"
vim.fn.writefile({
  "library(ggpl",
  "mtcars$mp",
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

ark_test.wait_for("initial syntax diagnostics", 10000, function()
  return #vim.diagnostic.get(0) > 0
end)

local initial_messages = diagnostic_messages()

if contains(initial_messages, "No symbol named 'mtcars' in scope.") then
  error(vim.inspect({
    stage = "initial diagnostics before pane startup",
    initial_diagnostics = initial_messages,
    status = require("ark").status({ include_lsp = true }),
  }), 0)
end

if not contains(initial_messages, "Unmatched opening delimiter. Missing a closing ')'." ) then
  error(vim.inspect({
    stage = "initial diagnostics before pane startup",
    initial_diagnostics = initial_messages,
    status = require("ark").status({ include_lsp = true }),
  }), 0)
end

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  error(pane_err or "failed to start managed pane", 0)
end

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
if not client or client:is_stopped() then
  error("ark_lsp client is not available after managed pane startup", 0)
end

local library_result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = 12 },
}, 10000)

local mtcars_result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 1, character = 9 },
}, 10000)

-- User keeps typing after the live session is available.
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "mtcars$mp " })

local diagnostics_settled = vim.wait(10000, function()
  local messages = diagnostic_messages()
  return not contains(messages, "No symbol named 'mtcars' in scope.")
end, 100, false)

local final_messages = diagnostic_messages()

if not diagnostics_settled then
  error(vim.inspect({
    initial_diagnostics = initial_messages,
    final_diagnostics = final_messages,
    library_completion = completion_labels(library_result),
    mtcars_completion = completion_labels(mtcars_result),
    status = require("ark").status(),
  }), 0)
end

if contains(final_messages, "No symbol named 'mtcars' in scope.") then
  error(vim.inspect({
    initial_diagnostics = initial_messages,
    final_diagnostics = final_messages,
    library_completion = completion_labels(library_result),
    mtcars_completion = completion_labels(mtcars_result),
    status = require("ark").status(),
  }), 0)
end

if not contains(final_messages, "Unmatched opening delimiter. Missing a closing ')'.") then
  error(vim.inspect({
    initial_diagnostics = initial_messages,
    final_diagnostics = final_messages,
    library_completion = completion_labels(library_result),
    mtcars_completion = completion_labels(mtcars_result),
    status = require("ark").status(),
  }), 0)
end

vim.print({
  initial_diagnostics = initial_messages,
  final_diagnostics = final_messages,
  library_completion = completion_labels(library_result),
  mtcars_completion = completion_labels(mtcars_result),
})
