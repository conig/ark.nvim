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

local test_file = "/tmp/ark_live_partial_scope_diagnostics.R"
local _, client = ark_test.setup_managed_buffer(test_file, {
  "library(ggpl",
  "mtcars$mp",
})

local library_result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = 12 },
}, 10000)

local mtcars_result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 1, character = 9 },
}, 10000)

vim.wait(3000, function()
  return #vim.diagnostic.get(0) > 0
end, 100, false)

local messages = diagnostic_messages()

if contains(messages, "No symbol named 'mtcars' in scope.") then
  error(vim.inspect({
    diagnostics = messages,
    library_completion = ark_test.item_labels(ark_test.completion_items(library_result)),
    mtcars_completion = ark_test.item_labels(ark_test.completion_items(mtcars_result)),
    status = require("ark").status(),
  }), 0)
end

vim.print({
  diagnostics = messages,
  library_completion = ark_test.item_labels(ark_test.completion_items(library_result)),
  mtcars_completion = ark_test.item_labels(ark_test.completion_items(mtcars_result)),
})
