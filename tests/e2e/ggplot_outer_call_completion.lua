local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_ggplot_outer_call_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "ggplot2::ggplot(mtcars,",
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
  ark_test.fail("ggplot2 is required for outer ggplot call completion coverage")
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

local line = vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
local column = assert(line:find(",", 1, true))

local function completion_at(context)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 0, character = column },
  }

  if context then
    params.context = context
  end

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local function assert_has_argument(label, items, argument)
  local item = ark_test.find_item(items, argument)
  if not item then
    ark_test.fail(label .. " missing " .. argument .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end

  local expected_insert = argument == "..." and "... = " or (argument .. " = ")
  if ark_test.insert_text(item) ~= expected_insert then
    ark_test.fail(label .. " inserted unexpected text for " .. argument .. ": " .. vim.inspect(item))
  end
end

local function assert_absent(label, items, unexpected)
  local item = ark_test.find_item(items, unexpected)
  if item then
    ark_test.fail(label .. " unexpectedly included " .. unexpected .. ": " .. vim.inspect(item))
  end
end

-- Regression coverage for the user-visible outer-call case: after the comma in
-- `ggplot2::ggplot(mtcars,`, completion should stay on `ggplot()` arguments
-- rather than switching into data-column or search-path completion.
local cases = {
  invoked = completion_at({ triggerKind = 1 }),
  comma = completion_at({ triggerKind = 2, triggerCharacter = "," }),
}

for label, items in pairs(cases) do
  for _, argument in ipairs({ "data", "mapping", "...", "environment" }) do
    assert_has_argument(label, items, argument)
  end

  for _, unexpected in ipairs({ "mpg", "cyl", "geom_point" }) do
    assert_absent(label, items, unexpected)
  end
end

print(vim.json.encode({
  invoked = vim.tbl_map(function(item)
    return item.label
  end, cases.invoked),
  comma = vim.tbl_map(function(item)
    return item.label
  end, cases.comma),
}))
