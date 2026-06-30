local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_ggplot_aes_empty_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "library(ggplot2)",
  "",
  "ggplot(mtcars, aes(",
  "ggplot(mtcars, aes(x",
})

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'ark_ggplot2_available <- requireNamespace("ggplot2", quietly = TRUE)',
  "Enter",
  "ark_ggplot2_available",
  "Enter",
})

ark_test.wait_for("ggplot2 availability probe", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil
end)

local has_ggplot2 = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id }):find("%[1%] TRUE") ~= nil
if not has_ggplot2 then
  ark_test.fail("ggplot2 is required for ggplot aes empty-prefix completion coverage")
end

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'suppressPackageStartupMessages(library(ggplot2)); ark_ggplot2_loaded <- "package:ggplot2" %in% search()',
  "Enter",
  "ark_ggplot2_loaded",
  "Enter",
})

ark_test.wait_for("ggplot2 attach", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil
end)

local function completion_at(line_nr, column)
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = {
      line = line_nr - 1,
      character = column,
    },
    context = {
      triggerKind = 1,
    },
  }, 10000))
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local empty_items = completion_at(3, #lines[3])
local prefixed_items = completion_at(4, #lines[4])

local function assert_argument_item(label, items, argument)
  local item = ark_test.find_item(items, argument)
  if not item then
    ark_test.fail(label .. " ggplot(mtcars, aes( completion missing " .. argument .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end
  local expected_insert = argument == "..." and "... = " or (argument .. " = ")
  if ark_test.insert_text(item) ~= expected_insert then
    ark_test.fail(label .. " ggplot(mtcars, aes( completion inserted unexpected text for " .. argument .. ": " .. vim.inspect(item))
  end
end

-- Empty and prefixed positions before `=` are formal-name slots. They should
-- complete `aes()` arguments, not infer columns from a nearby `ggplot(data)`.
for _, argument in ipairs({ "x", "y", "..." }) do
  assert_argument_item("empty", empty_items, argument)
end
assert_argument_item("prefixed", prefixed_items, "x")

for _, label in ipairs({ "mpg", "cyl", "disp", "hp", "drat", "wt", "qsec", "vs", "am", "gear", "carb" }) do
  for case, items in pairs({ empty = empty_items, prefixed = prefixed_items }) do
    local item = ark_test.find_item(items, label)
    if item then
      ark_test.fail(case .. " ggplot(mtcars, aes( completion unexpectedly included data column " .. label .. ": " .. vim.inspect(ark_test.item_labels(items)))
    end
  end
end

print(vim.json.encode({
  empty = ark_test.item_labels(empty_items),
  prefixed = ark_test.item_labels(prefixed_items),
}))
