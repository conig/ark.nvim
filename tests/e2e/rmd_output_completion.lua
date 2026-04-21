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

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_rmd_output_completion.Rmd"

vim.fn.writefile({
  "---",
  "output: rmarkdown::h",
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

vim.api.nvim_buf_set_text(0, 1, 20, 1, 20, { "t" })
vim.wait(500, function()
  return false
end, 500, false)

local line = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
local completion_column = #line
local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local result = request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 1, character = completion_column },
}, 10000)

local items = completion_items(result)
local labels = item_labels(items)
local expected = {
  "rmarkdown::html_document",
  "rmarkdown::pdf_document",
  "rmarkdown::word_document",
  "rmarkdown::beamer_presentation",
  "rmarkdown::ioslides_presentation",
  "rmarkdown::slidy_presentation",
}

if #labels ~= #expected then
  fail("unexpected frontmatter output completion set: " .. vim.inspect(labels))
end

for i, label in ipairs(expected) do
  if labels[i] ~= label then
    fail("frontmatter output completion polluted or reordered: " .. vim.inspect(labels))
  end
end

local html = find_item(items, "rmarkdown::html_document")
if not html then
  fail("output completion missing html_document: " .. vim.inspect(labels))
end

local text_edit = html.textEdit or html.text_edit
if not text_edit or text_edit.newText ~= "rmarkdown::html_document" then
  fail("output completion returned unexpected text edit: " .. vim.inspect(text_edit))
end

vim.print({
  completions = labels,
  html_text_edit = text_edit,
})
