local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
end

local function diagnostic_messages()
  local diagnostics = vim.diagnostic.get(0)
  local messages = {}

  for _, diagnostic in ipairs(diagnostics) do
    messages[#messages + 1] = diagnostic.message
  end

  return messages
end

local function any_message_contains(messages, needle)
  for _, message in ipairs(messages) do
    if message:find(needle, 1, true) then
      return true
    end
  end

  return false
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_base_diagnostics.R"

vim.fn.writefile({
  "library(ggplot2)",
  "",
  "browser()",
  "",
  "undefined_symbol_ark",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true
end)

wait_for("semantic diagnostics", 10000, function()
  local messages = diagnostic_messages()
  return #messages >= 1
    and not any_message_contains(messages, "No symbol named 'library' in scope.")
    and not any_message_contains(messages, "No symbol named 'browser' in scope.")
    and any_message_contains(messages, "No symbol named 'undefined_symbol_ark' in scope.")
end)

local messages = diagnostic_messages()

if not any_message_contains(messages, "No symbol named 'undefined_symbol_ark' in scope.") then
  fail("expected undefined symbol diagnostic, got: " .. vim.inspect(messages))
end

vim.print({
  diagnostics = messages,
})
