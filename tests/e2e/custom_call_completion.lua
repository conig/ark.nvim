local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_custom_call_completion.R"
local env_name = "PATH"
local option_name = "warn"

-- This reproduces detached product-mode custom-call completions that existed in
-- the old in-process path but were not routed through the detached session
-- bridge: env vars and option names in both string and bare-call forms.
local _, client = ark_test.setup_managed_buffer(test_file, {
  'Sys.getenv("PA")',
  "Sys.unsetenv(PA)",
  'getOption("war")',
  "options(war)",
  "Sys.setenv(PA)",
})

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

local function completion_at(line, column, context)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }

  if context then
    params.context = context
  end

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local function assert_item(label, items, expected_label, expected_insert_text, expected_command)
  local item = ark_test.find_item(items, expected_label)
  if not item then
    ark_test.fail(label .. " missing " .. expected_label .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end

  if ark_test.insert_text(item) ~= expected_insert_text then
    ark_test.fail(label .. " inserted unexpected text: " .. vim.inspect(item))
  end

  local command = item.command and item.command.command or nil
  if command ~= expected_command then
    ark_test.fail(label .. " command mismatch: " .. vim.inspect(item))
  end

  return item
end

local getenv_items = completion_at(1, assert(lines[1]:find('")', 1, true)) - 1, {
  triggerKind = 1,
})
assert_item('Sys.getenv("', getenv_items, env_name, env_name, "ark.completeStringDelimiter")

local unsetenv_items = completion_at(2, assert(lines[2]:find(")", 1, true)) - 1, {
  triggerKind = 1,
})
assert_item("Sys.unsetenv(", unsetenv_items, env_name, '"' .. env_name .. '"', nil)

local get_option_items = completion_at(3, assert(lines[3]:find('")', 1, true)) - 1, {
  triggerKind = 1,
})
assert_item('getOption("', get_option_items, option_name, option_name, "ark.completeStringDelimiter")

local options_items = completion_at(4, assert(lines[4]:find(")", 1, true)) - 1, {
  triggerKind = 1,
})
assert_item("options(", options_items, option_name, option_name .. " = ", nil)

local setenv_items = completion_at(5, assert(lines[5]:find(")", 1, true)) - 1, {
  triggerKind = 1,
})
assert_item("Sys.setenv(", setenv_items, env_name, env_name .. " = ", nil)

vim.print({
  getenv = env_name,
  unsetenv = env_name,
  getOption = option_name,
  options = option_name,
  setenv = env_name,
})
