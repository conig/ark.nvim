local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_argument_completion_after_named_comma.R"

-- Regression for argument-name completion after the first comma in a call
-- whose first argument is named. This mirrors typing `lm(data = mtcars, `
-- and requesting completion at the empty next argument position.
local _, client = ark_test.setup_managed_buffer(test_file, {
  "lm(data = mtcars, ",
})

local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
local result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = {
    line = 0,
    character = #line,
  },
  context = {
    triggerKind = 1,
  },
}, 10000)

local items = ark_test.completion_items(result)
for _, label in ipairs({ "formula", "subset" }) do
  local item = ark_test.find_item(items, label)
  if not item then
    ark_test.fail("lm(data = mtcars, completion missing " .. label .. ": " .. vim.inspect(ark_test.item_labels(items)))
  end
  if ark_test.insert_text(item) ~= label .. " = " then
    ark_test.fail("lm(data = mtcars, completion inserted unexpected text for " .. label .. ": " .. vim.inspect(item))
  end
end

vim.print({
  lm_argument_completion_after_named_comma = "ok",
})
