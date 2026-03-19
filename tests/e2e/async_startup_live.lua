local ark_test = require("ark_test")

local function completion_at(client, line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }
  local result = ark_test.request(client, "textDocument/completion", params, 10000)
  return ark_test.completion_items(result)
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_async_startup_live.R"

vim.fn.writefile({
  "whi",
  'library("uti',
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]

local keyword_items = completion_at(client, 1, 3)
local while_keyword = ark_test.find_item(keyword_items, "while")
if not while_keyword then
  error("async startup keyword completion missing while: " .. vim.inspect(keyword_items), 0)
end

local library_items = completion_at(client, 2, 12)
local utils_pkg = ark_test.find_item(library_items, "utils")
if not utils_pkg then
  error('async startup quoted library() completion missing utils: ' .. vim.inspect(library_items), 0)
end

vim.print({
  keyword = while_keyword.label,
  library = utils_pkg.label,
})
