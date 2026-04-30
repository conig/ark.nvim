local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function open_file(path)
  vim.cmd("edit " .. path)
  vim.cmd("setfiletype r")
end

local function start_lsp_for_current_buffer()
  local lsp_config = require("ark").lsp_config(0)
  ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

  require("ark").start_lsp(0)

  ark_test.wait_for("ark lsp client", 15000, function()
    local client = current_client()
    return client ~= nil and client.initialized == true and not client:is_stopped()
  end)

  return current_client()
end

local function request_current(method, params, timeout_ms)
  local client = current_client()
  if not client then
    fail("ark_lsp client unavailable for " .. method)
  end

  return ark_test.request(client, method, params, timeout_ms or 10000)
end

local function text_document_params(bufnr)
  return vim.lsp.util.make_text_document_params(bufnr or 0)
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/definition-open-buffer-index")
vim.fn.mkdir(root, "p")

local def_file = root .. "/helpers.R"
local ref_file = root .. "/main.R"

-- The definition exists only in the live opened buffer. A disk-only workspace
-- scan cannot see it, so go-to-definition depends on indexing didOpen content.
vim.fn.writefile({ "" }, def_file)
vim.fn.writefile({
  "result <- unsaved_helper(1)",
}, ref_file)

open_file(def_file)
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "unsaved_helper <- function(value) {",
  "  value + 1",
  "}",
})

start_lsp_for_current_buffer()

open_file(ref_file)
start_lsp_for_current_buffer()

local ref_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
local call_start = assert(ref_line:find("unsaved_helper", 1, true)) - 1

local definition = request_current("textDocument/definition", {
  textDocument = text_document_params(0),
  position = {
    line = 0,
    character = call_start,
  },
})

if type(definition) ~= "table" or vim.tbl_isempty(definition) then
  fail("expected definition result for unsaved helper: " .. vim.inspect(definition))
end

local definition_target = definition[1]
local definition_uri = definition_target.targetUri or definition_target.uri
if vim.fs.normalize(vim.uri_to_fname(definition_uri)) ~= vim.fs.normalize(def_file) then
  fail("definition resolved to unexpected file: " .. vim.inspect(definition))
end

vim.print({
  definition = definition_uri,
})
