local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function definition_uri(client, character)
  local definition = ark_test.request(client, "textDocument/definition", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 0, character = character },
  }, 5000)
  if type(definition) ~= "table" or not definition[1] then
    return nil
  end
  return definition[1].targetUri or definition[1].uri
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local fixture = vim.fs.normalize(ark_test.run_tmpdir() .. "/workspace-folder-changes")
local root_a = fixture .. "/root-a"
local root_b = fixture .. "/root-b"
vim.fn.mkdir(root_a, "p")
vim.fn.mkdir(root_b, "p")

local main_file = root_a .. "/main.R"
local helper_file = root_b .. "/helper.R"
vim.fn.writefile({ "result <- added_workspace_helper(1)" }, main_file)
vim.fn.writefile({ "added_workspace_helper <- function(value) value + 1" }, helper_file)

vim.cmd("edit " .. vim.fn.fnameescape(main_file))
vim.cmd("setfiletype r")
local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)
require("ark").start_lsp(0)

ark_test.wait_for("ark lsp client", 5000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local client = current_client()
local character = assert(vim.api.nvim_get_current_line():find("added_workspace_helper", 1, true)) - 1
local initial_definition = definition_uri(client, character)
if type(initial_definition) == "string"
  and vim.fs.normalize(vim.uri_to_fname(initial_definition)) == vim.fs.normalize(helper_file)
then
  fail("definition unexpectedly resolved outside the active workspace roots")
end

client:notify("workspace/didChangeWorkspaceFolders", {
  event = {
    added = { { uri = vim.uri_from_fname(root_b), name = "root-b" } },
    removed = {},
  },
})

local added_definition = nil
ark_test.wait_for("added workspace root index", 10000, function()
  added_definition = definition_uri(client, character)
  return type(added_definition) == "string"
    and vim.fs.normalize(vim.uri_to_fname(added_definition)) == vim.fs.normalize(helper_file)
end)

client:notify("workspace/didChangeWorkspaceFolders", {
  event = {
    added = {},
    removed = { { uri = vim.uri_from_fname(root_b), name = "root-b" } },
  },
})

ark_test.wait_for("removed workspace root eviction", 5000, function()
  local definition = definition_uri(client, character)
  return type(definition) ~= "string"
    or vim.fs.normalize(vim.uri_to_fname(definition)) ~= vim.fs.normalize(helper_file)
end)

vim.print({
  added_definition = added_definition,
  removed = true,
})
