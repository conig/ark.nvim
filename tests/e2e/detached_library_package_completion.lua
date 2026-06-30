local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function completion_at(line, column)
  local client = current_client()
  if not client then
    ark_test.fail("ark_lsp client unavailable")
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = { triggerKind = 1 },
  }

  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local function assert_package_item(label, line, expected_insert, expect_command)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local close = lines[line]:find(")", 1, true)
  local column = close and (close - 1) or #lines[line]
  local items = completion_at(line, column)
  local item = ark_test.find_item(items, "utils")
  if not item then
    ark_test.fail(label .. " missing utils: " .. vim.inspect(ark_test.item_labels(items)))
  end

  if ark_test.insert_text(item) ~= expected_insert then
    ark_test.fail(label .. " inserted unexpected text: " .. vim.inspect(item))
  end

  local has_command = item.command ~= nil
  if has_command ~= expect_command then
    ark_test.fail(label .. " command mismatch: " .. vim.inspect(item))
  end
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_detached_library_package_completion.R"

vim.fn.writefile({
  "library(uti)",
  "uti",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(0)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

ark_test.wait_for("detached installed-package metadata", 30000, function()
  local status = require("ark").status({ include_lsp = true })
  local lsp_status = status and status.lsp_status or nil
  return type(lsp_status) == "table"
    and lsp_status.runtimeMode == "detached"
    and tonumber(lsp_status.installedPackageCount or 0) > 0
end)

assert_package_item("library package argument", 1, "utils", false)
assert_package_item("namespace root", 2, "utils::", true)

vim.print({
  library_package = "utils",
  namespace_root = "utils::",
})
