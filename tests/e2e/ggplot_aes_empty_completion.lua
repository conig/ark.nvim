local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_ggplot_aes_empty_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "library(ggplot2)",
  "",
  "ggplot(mtcars, aes(",
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

local line = vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
local items = ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = {
    line = 2,
    character = #line,
  },
  context = {
    triggerKind = 1,
  },
}, 10000))

-- Regression coverage for an empty-prefix mapping context. `aes(cy|)` already
-- worked; this checks the user-visible spot right after typing `aes(`.
local labels = ark_test.item_labels(items)
for _, label in ipairs({ "mpg", "cyl", "disp", "hp", "drat", "wt", "qsec", "vs", "am", "gear", "carb" }) do
  local item = ark_test.find_item(items, label)
  if not item then
    ark_test.fail("ggplot(mtcars, aes( completion missing " .. label .. ": " .. vim.inspect(labels))
  end
  if ark_test.insert_text(item) ~= label then
    ark_test.fail("ggplot(mtcars, aes( completion inserted unexpected text for " .. label .. ": " .. vim.inspect(item))
  end
end

print(vim.json.encode({
  count = #items,
  labels = labels,
}))
