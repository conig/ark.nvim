local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_data_context_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "ggplot(data = mtcars, aes(x = ",
  "ggplot(mtcars, aes(x = cy))",
  "mtcars |> ggplot(aes(x = cy))",
  "ggplot(data = mtcars, aes(x = mpg, y = ",
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

local has_ggplot2 = ark_test
  .tmux({ "capture-pane", "-p", "-t", pane_id })
  :find("%[1%] TRUE") ~= nil

if not has_ggplot2 then
  ark_test.fail("ggplot2 is required for data-context completion e2e coverage")
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

local function completion_at(line, column)
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = { triggerKind = 1 },
  }, 10000))
end

local function assert_empty(label, items)
  if #items ~= 0 then
    ark_test.fail(label .. " expected no completions, got: " .. vim.inspect(ark_test.item_labels(items)))
  end
end

local function assert_no_inferred_call_value_items(label, items)
  local labels = ark_test.item_labels(items)
  for _, unexpected in ipairs({ "mpg", "cyl", "disp", "hp", "drat", "wt", "qsec", "vs", "am", "gear", "carb", "x", "y", "..." }) do
    if ark_test.find_item(items, unexpected) then
      ark_test.fail(label .. " unexpectedly included " .. unexpected .. ": " .. vim.inspect(labels))
    end
  end
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

-- After `=`, the function data model only tells us that we are in an argument
-- value. It does not declare that this value should be a column of a nearby
-- `data` argument or pipe root, so Ark should not infer data-column completions.
assert_empty("ggplot(data = mtcars, aes(x = explicit completion", completion_at(1, #lines[1]))
assert_no_inferred_call_value_items(
  "ggplot(mtcars, aes(x = cy explicit completion",
  completion_at(2, assert(lines[2]:find("cy", 1, true)) + 1)
)
assert_no_inferred_call_value_items(
  "mtcars |> ggplot(aes(x = cy explicit completion",
  completion_at(3, assert(lines[3]:find("cy", 1, true)) + 1)
)
assert_empty("ggplot(..., aes(..., y = explicit completion", completion_at(4, #lines[4]))

print(vim.json.encode({
  named_empty = ark_test.item_labels(completion_at(1, #lines[1])),
  named_prefix = ark_test.item_labels(completion_at(2, assert(lines[2]:find("cy", 1, true)) + 1)),
  piped_prefix = ark_test.item_labels(completion_at(3, assert(lines[3]:find("cy", 1, true)) + 1)),
  second_named_empty = ark_test.item_labels(completion_at(4, #lines[4])),
}))
