local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_package_string_completion_single_quotes.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  "requireNamespace('uti')",
  "loadNamespace('uti')",
  "find.package('uti')",
  "packageVersion(pkg = 'uti')",
  "getNamespace('uti')",
})

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = { triggerKind = 1 },
  }

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local function assert_package_string_completion(label, line)
  local column = assert(lines[line]:find("')", 1, true)) - 1
  local items = completion_at(line, column)
  local item = ark_test.find_item(items, "utils")
  if not item then
    ark_test.fail(label .. " missing utils: " .. vim.inspect(ark_test.item_labels(items)))
  end

  if ark_test.insert_text(item) ~= "utils" then
    ark_test.fail(label .. " inserted unexpected text: " .. vim.inspect(item))
  end

  local command = item.command and item.command.command or nil
  if command ~= "ark.completeStringDelimiter" then
    ark_test.fail(label .. " command mismatch: " .. vim.inspect(item))
  end
end

assert_package_string_completion("requireNamespace('", 1)
assert_package_string_completion("loadNamespace('", 2)
assert_package_string_completion("find.package('", 3)
assert_package_string_completion("packageVersion(pkg = '", 4)
assert_package_string_completion("getNamespace('", 5)

vim.print({
  requireNamespace = "utils",
  loadNamespace = "utils",
  find_package = "utils",
  packageVersion = "utils",
  getNamespace = "utils",
})
