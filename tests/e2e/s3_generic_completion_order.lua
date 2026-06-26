local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_s3_generic_completion_order.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  "summ",
})

local function completion_at(line, column)
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = { triggerKind = 1 },
  }, 10000))
end

local function item_sort_text(item)
  return item.sortText or item.sort_text or item.label
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local items = completion_at(1, #lines[1])
local labels = ark_test.item_labels(items)

local generic = ark_test.find_item(items, "summary")
if not generic then
  ark_test.fail("summary completion missing: " .. vim.inspect(labels))
end

-- Regression: class-specific S3 methods from earlier search-path packages,
-- such as stats::summary.aov, must not outrank the main generic users typed.
local method = ark_test.find_item(items, "summary.aov")
if not method then
  ark_test.fail("summary.aov completion missing: " .. vim.inspect(labels))
end

local generic_sort = item_sort_text(generic)
local method_sort = item_sort_text(method)
if generic_sort >= method_sort then
  ark_test.fail(
    "summary should sort before summary.aov, got summary="
      .. vim.inspect(generic_sort)
      .. " summary.aov="
      .. vim.inspect(method_sort)
      .. " labels="
      .. vim.inspect(labels)
  )
end

print(vim.json.encode({
  summary_sort = generic_sort,
  summary_aov_sort = method_sort,
  labels = labels,
}))
