local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_extractor_completion.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "",
})

local function reset_buffer(line)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { line })
end

ark_test.wait_for("detached ark_lsp hydration", 10000, function()
  local status = require("ark").status({ include_lsp = true })
  local lsp_status = status and status.lsp_status or nil
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

local function completion_at(line, column, trigger_character)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = {
      triggerKind = 2,
      triggerCharacter = trigger_character,
    },
  }

  local result = ark_test.request(client, "textDocument/completion", params)
  return result, ark_test.completion_items(result)
end

reset_buffer("mtcars$")
local empty_rhs_result, empty_rhs_items = nil, {}
ark_test.wait_for("mtcars$ completion", 5000, function()
  empty_rhs_result, empty_rhs_items = completion_at(1, 7, "$")
  return ark_test.find_item(empty_rhs_items, "mpg") ~= nil
end)
local empty_rhs = ark_test.find_item(empty_rhs_items, "mpg")
if not empty_rhs then
  ark_test.fail("mtcars$ completion missing mpg: " .. vim.inspect({
    result = empty_rhs_result,
    labels = ark_test.item_labels(empty_rhs_items),
    status = require("ark").status({ include_lsp = true }),
  }))
end

reset_buffer("mtcars$mp")
local prefixed_rhs_result, prefixed_rhs_items = nil, {}
ark_test.wait_for("mtcars$mp completion", 5000, function()
  prefixed_rhs_result, prefixed_rhs_items = completion_at(1, 9, "$")
  return ark_test.find_item(prefixed_rhs_items, "mpg") ~= nil
end)
local prefixed_rhs = ark_test.find_item(prefixed_rhs_items, "mpg")
if not prefixed_rhs then
  ark_test.fail("mtcars$mp completion missing mpg: " .. vim.inspect({
    result = prefixed_rhs_result,
    labels = ark_test.item_labels(prefixed_rhs_items),
    status = require("ark").status({ include_lsp = true }),
  }))
end

vim.print({
  mtcars_dollar = ark_test.insert_text(empty_rhs),
  mtcars_dollar_prefixed = ark_test.insert_text(prefixed_rhs),
})
