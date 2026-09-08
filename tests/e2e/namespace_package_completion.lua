local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_namespace_package_completion.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  "uti::",
  "uti:::",
  "utils::head",
  "utils:::as.bibentry",
  "dplyr:::",
  "list(dplyr:::)",
  "dplyr:::check_",
  "dplyr::",
})

local function completion_at(line, column, trigger)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = { triggerKind = trigger and 2 or 1, triggerCharacter = trigger },
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

local function assert_namespace_member_completion(label, line, member)
  local column = #vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  local items = completion_at(line, column)
  local item = ark_test.find_item(items, member)
  if not item then
    ark_test.fail(label .. " missing " .. member .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end
end

assert_namespace_member_completion("pkg::", 3, "head")

-- Internal namespace members are only available through the managed R session.
assert_namespace_member_completion("pkg:::", 4, "as.bibentry.bibentry")

-- The third colon should offer internals with no prefix, including before an
-- auto-closed delimiter. A typed prefix must also find internal functions.
for _, case in ipairs({
  { line = 5, column = 8, trigger = ":" },
  { line = 6, column = 13, trigger = ":" },
  { line = 7, column = 14 },
}) do
  local items = completion_at(case.line, case.column, case.trigger)
  if not ark_test.find_item(items, "check_filter") then
    ark_test.fail("dplyr::: missing check_filter on line " .. case.line
      .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end
end
local exports = completion_at(8, 7, ":")
assert(ark_test.find_item(exports, "mutate"), "dplyr:: missing mutate")
assert(not ark_test.find_item(exports, "check_filter"), "dplyr:: leaked internals")

vim.print({
  namespace = "utils",
  internal_namespace = "utils",
  exported_member = "head",
  internal_member = "as.bibentry.bibentry",
})
