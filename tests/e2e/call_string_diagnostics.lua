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

-- Regression scenario: base search-path functions should not be flagged as
-- undefined when detached diagnostics hydrate after the managed REPL is ready.
local test_file = "/tmp/ark_call_string_diagnostics.R"
local _, _ = ark_test.setup_managed_buffer(test_file, {
  'cor(mtcars, method = "spearman")',
})

ark_test.wait_for("detached session bootstrap", 10000, function()
  local status = require("ark").status({ include_lsp = true })
  local lsp_status = status and status.lsp_status or {}
  local detached_status = lsp_status and lsp_status.detachedSessionStatus or {}
  return detached_status.lastBootstrapSuccessMs ~= nil
end)

local settled = vim.wait(3000, function()
  return false
end, 100, false)

local messages = diagnostic_messages()
if contains(messages, "No symbol named 'cor' in scope.") then
  ark_test.fail(vim.inspect({
    diagnostics = messages,
    settled = settled,
    status = require("ark").status({ include_lsp = true }),
  }))
end

if contains(messages, "No symbol named 'mtcars' in scope.") then
  ark_test.fail(vim.inspect({
    diagnostics = messages,
    settled = settled,
    status = require("ark").status({ include_lsp = true }),
  }))
end

vim.print({
  diagnostics = messages,
  settled = settled,
  status = require("ark").status({ include_lsp = true }),
})
