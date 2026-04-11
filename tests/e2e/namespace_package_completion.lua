local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_namespace_package_completion.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  "uti::",
  "uti:::",
})

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = { triggerKind = 1 },
  }

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local function assert_namespace_package_completion(label, line)
  local items = completion_at(line, 3)
  local item = ark_test.find_item(items, "utils")
  if not item then
    ark_test.fail(label .. " missing utils: " .. vim.inspect(ark_test.item_labels(items)))
  end

  if ark_test.insert_text(item) ~= "utils" then
    ark_test.fail(label .. " inserted unexpected text: " .. vim.inspect(item))
  end

  if item.command ~= nil then
    ark_test.fail(label .. " should not trigger a follow-up command: " .. vim.inspect(item))
  end
end

assert_namespace_package_completion("pkg::", 1)
assert_namespace_package_completion("pkg:::", 2)

vim.print({
  namespace = "utils",
  internal_namespace = "utils",
})
