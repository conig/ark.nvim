local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_data_context_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "ggplot(data = mtcars, aes(cy))",
  "ggplot(mtcars, aes(cy))",
  "mtcars |> ggplot(aes(cy))",
  "ggplot(data = mtcars, aes(x = cy))",
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

local function completion_at(line, column, trigger_kind)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }

  if trigger_kind then
    params.context = {
      triggerKind = trigger_kind,
    }
  end

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local function assert_has_cyl(label, items)
  local cyl = ark_test.find_item(items, "cyl")
  if not cyl then
    ark_test.fail(label .. " missing cyl: " .. vim.inspect(ark_test.item_labels(items)))
  end
  if ark_test.insert_text(cyl) ~= "cyl" then
    ark_test.fail(label .. " inserted unexpected text: " .. vim.inspect(cyl))
  end
  return cyl
end

local function assert_no_cyl(label, items)
  local cyl = ark_test.find_item(items, "cyl")
  if cyl then
    ark_test.fail(label .. " unexpectedly included cyl: " .. vim.inspect(cyl))
  end
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

local explicit_named_items = completion_at(1, assert(lines[1]:find("cy)", 1, true)) + 1, 1)
assert_has_cyl("ggplot(data = mtcars, aes(cy explicit completion", explicit_named_items)

local nonexplicit_named_items = completion_at(1, assert(lines[1]:find("cy)", 1, true)) + 1)
assert_no_cyl("ggplot(data = mtcars, aes(cy implicit completion", nonexplicit_named_items)

local positional_items = completion_at(2, assert(lines[2]:find("cy)", 1, true)) + 1, 1)
assert_has_cyl("ggplot(mtcars, aes(cy explicit completion", positional_items)

local piped_items = completion_at(3, assert(lines[3]:find("cy)", 1, true)) + 1, 1)
assert_has_cyl("mtcars |> ggplot(aes(cy explicit completion", piped_items)

local result = {
  named = ark_test.insert_text(ark_test.find_item(explicit_named_items, "cyl")),
  positional = ark_test.insert_text(ark_test.find_item(positional_items, "cyl")),
  piped = ark_test.insert_text(ark_test.find_item(piped_items, "cyl")),
}

local ggplot_items = completion_at(4, assert(lines[4]:find("cy)", 1, true)) + 1, 1)
local ggplot_cyl = assert_has_cyl("ggplot(..., aes(x = cy explicit completion", ggplot_items)
result.ggplot = ark_test.insert_text(ggplot_cyl)

print(vim.json.encode(result))
