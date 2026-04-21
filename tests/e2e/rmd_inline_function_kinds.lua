local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_rmd_inline_function_kinds.Rmd"

vim.fn.writefile({
  "---",
  'title: "Ark inline R function kinds"',
  "---",
  "",
  "The call is `r la`.",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype rmd")

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

require("ark").refresh(0)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local function completion_items_for(prefix)
  vim.api.nvim_buf_set_lines(0, 4, 5, false, {
    "The call is `r " .. prefix .. "`.",
  })

  vim.wait(300, function()
    return false
  end, 50, false)

  local line = vim.api.nvim_buf_get_lines(0, 4, 5, false)[1]
  local completion_column = assert(line:find("`.", 1, true)) - 1

  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  local result = ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 4, character = completion_column },
  }, 10000)

  return ark_test.completion_items(result)
end

local function assert_function_item(prefix, label)
  local items = completion_items_for(prefix)
  local item = ark_test.find_item(items, label)
  if not item then
    ark_test.fail(
      "inline function completion missing " .. label .. " for prefix " .. prefix .. ": " .. vim.inspect(items)
    )
  end

  local function_kind = vim.lsp.protocol.CompletionItemKind.Function
  if item.kind ~= function_kind then
    ark_test.fail(
      "inline function completion returned non-function kind for "
        .. label
        .. ": "
        .. vim.inspect(item)
    )
  end
end

-- Mirror literate-R inline typing: runtime function prefixes should keep
-- surfacing function candidates as functions, not as generic variables.
assert_function_item("la", "lapply")
assert_function_item("nr", "nrow")

vim.print({
  status = "ok",
})
