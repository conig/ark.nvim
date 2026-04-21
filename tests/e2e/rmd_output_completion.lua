local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
end

local function request(client, method, params, timeout_ms)
  local response, err = client:request_sync(method, params, timeout_ms or 10000, 0)
  if err then
    fail(method .. " error: " .. err)
  end
  if not response then
    fail("no response for " .. method)
  end
  if response.error or response.err then
    fail(method .. " error: " .. vim.inspect(response.error or response.err))
  end
  return response.result
end

local function completion_items(result)
  if type(result) ~= "table" then
    return {}
  end
  if vim.islist(result) then
    return result
  end
  return result.items or {}
end

local function item_labels(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.label
  end
  return out
end

local function find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function assert_exact_labels(items, expected, label)
  local labels = item_labels(items)

  if #labels ~= #expected then
    fail(label .. ": unexpected frontmatter output completion set: " .. vim.inspect(labels))
  end

  for index, value in ipairs(expected) do
    if labels[index] ~= value then
      fail(label .. ": frontmatter output completion polluted or reordered: " .. vim.inspect(labels))
    end
  end
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_rmd_output_completion.Rmd"

vim.fn.writefile({
  "---",
  "output: ",
  'title: "Ark R Markdown output completion"',
  "---",
  "",
  "Body",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype rmd")

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local expected = {
  "html_document",
  "pdf_document",
  "word_document",
  "beamer_presentation",
  "ioslides_presentation",
  "slidy_presentation",
}

local function request_output_completion(line_text)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "---",
    line_text,
    'title: "Ark R Markdown output completion"',
    "---",
    "",
    "Body",
  })
  vim.wait(300, function()
    return false
  end, 50, false)

  local result = request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 1, character = #line_text },
  }, 10000)

  return completion_items(result)
end

local colon_items = request_output_completion("output:")
assert_exact_labels(colon_items, expected, "colon trigger")

local colon_html = find_item(colon_items, "html_document")
if not colon_html then
  fail("colon trigger output completion missing html_document: " .. vim.inspect(item_labels(colon_items)))
end

local colon_text_edit = colon_html.textEdit or colon_html.text_edit
if not colon_text_edit or colon_text_edit.newText ~= " html_document" then
  fail("colon trigger output completion returned unexpected text edit: " .. vim.inspect(colon_text_edit))
end

local empty_items = request_output_completion("output: ")
assert_exact_labels(empty_items, expected, "empty prefix")

local partial_items = request_output_completion("output: ht")
assert_exact_labels(partial_items, expected, "partial prefix")

local html = find_item(partial_items, "html_document")
if not html then
  fail("output completion missing html_document: " .. vim.inspect(item_labels(partial_items)))
end

local text_edit = html.textEdit or html.text_edit
if not text_edit or text_edit.newText ~= "html_document" then
  fail("output completion returned unexpected text edit: " .. vim.inspect(text_edit))
end

local exact_items = request_output_completion("output: html_document")
if #exact_items ~= 0 then
  fail("exact builtin output should suppress further completions: " .. vim.inspect(item_labels(exact_items)))
end

local spaced_items = request_output_completion("output: html_document ")
if #spaced_items ~= 0 then
  fail("exact builtin output with trailing space should suppress further completions: " .. vim.inspect(item_labels(spaced_items)))
end

vim.print({
  colon_prefix = item_labels(colon_items),
  colon_html_text_edit = colon_text_edit,
  empty_prefix = item_labels(empty_items),
  partial_prefix = item_labels(partial_items),
  html_text_edit = text_edit,
  exact_builtin_items = #exact_items,
  exact_builtin_spaced_items = #spaced_items,
})
