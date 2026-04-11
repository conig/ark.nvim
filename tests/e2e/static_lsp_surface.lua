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

local function find_document_symbol(symbols, name)
  for _, symbol in ipairs(symbols or {}) do
    if symbol.name == name then
      return symbol
    end
  end
  return nil
end

local function any_location_in_file(locations, path)
  local expected = vim.fs.normalize(path)
  for _, location in ipairs(locations or {}) do
    local uri = location.uri or (location.targetUri)
    if type(uri) == "string" then
      local actual = vim.uri_to_fname(uri)
      if vim.fs.normalize(actual) == expected then
        return true
      end
    end
  end
  return false
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/static-lsp-surface")
vim.fn.mkdir(root, "p")

local main_file = root .. "/main.R"
local ref_file = root .. "/ref.R"

vim.fn.writefile({
  "alpha <- function(value) {",
  "  inner <- function() value",
  "  inner()",
  "}",
  "",
  "beta <- alpha(1)",
}, main_file)

vim.fn.writefile({
  "gamma <- alpha(2)",
  "alpha",
}, ref_file)

open_file(main_file)
start_lsp_for_current_buffer()

ark_test.wait_for("workspace symbol indexing", 10000, function()
  local result = request_current("workspace/symbol", {
    query = "alpha",
  }, 10000)

  for _, item in ipairs(result or {}) do
    if item.name == "alpha" and any_location_in_file({ item.location }, main_file) then
      return true
    end
  end

  return false
end)

local document_symbols = request_current("textDocument/documentSymbol", {
  textDocument = text_document_params(0),
})

if type(document_symbols) ~= "table" or vim.tbl_isempty(document_symbols) then
  fail("document symbols request returned no symbols: " .. vim.inspect(document_symbols))
end

local alpha_symbol = find_document_symbol(document_symbols, "alpha")
if not alpha_symbol then
  fail("document symbols missing alpha: " .. vim.inspect(document_symbols))
end

local beta_symbol = find_document_symbol(document_symbols, "beta")
if not beta_symbol then
  fail("document symbols missing beta: " .. vim.inspect(document_symbols))
end

local inner_symbol = find_document_symbol(alpha_symbol.children or {}, "inner")
if not inner_symbol then
  fail("document symbols missing nested inner function: " .. vim.inspect(alpha_symbol))
end

local code_actions = request_current("textDocument/codeAction", {
  textDocument = text_document_params(0),
  range = {
    start = { line = 0, character = 2 },
    ["end"] = { line = 0, character = 2 },
  },
  context = {
    diagnostics = {},
  },
})

if type(code_actions) ~= "table" or vim.tbl_isempty(code_actions) then
  fail(vim.inspect({
    error = "expected roxygen code action at top-level function name",
    code_actions = code_actions,
    server_capabilities = current_client() and current_client().server_capabilities or nil,
  }))
end

local roxygen_action = nil
for _, action in ipairs(code_actions) do
  local candidate = action.command or action
  if candidate.title == "Generate a roxygen template" then
    roxygen_action = candidate
    break
  end
end

if not roxygen_action then
  fail("missing roxygen code action: " .. vim.inspect(code_actions))
end

local workspace_symbols = request_current("workspace/symbol", {
  query = "alpha",
})

if vim.tbl_isempty(workspace_symbols or {}) then
  fail("workspace symbol query returned no results for alpha")
end

local alpha_workspace_symbol = nil
for _, item in ipairs(workspace_symbols) do
  if item.name == "alpha" and any_location_in_file({ item.location }, main_file) then
    alpha_workspace_symbol = item
    break
  end
end

if not alpha_workspace_symbol then
  fail("workspace symbol query missing alpha in main.R: " .. vim.inspect(workspace_symbols))
end

open_file(ref_file)
start_lsp_for_current_buffer()

local ref_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
local alpha_call_start = assert(ref_line:find("alpha", 1, true)) - 1

local definition = request_current("textDocument/definition", {
  textDocument = text_document_params(0),
  position = {
    line = 0,
    character = alpha_call_start,
  },
})

if type(definition) ~= "table" or vim.tbl_isempty(definition) then
  fail("expected definition result for alpha call: " .. vim.inspect(definition))
end

local definition_target = definition[1]
local definition_uri = definition_target.targetUri or definition_target.uri
if vim.fs.normalize(vim.uri_to_fname(definition_uri)) ~= vim.fs.normalize(main_file) then
  fail("definition resolved to unexpected file: " .. vim.inspect(definition))
end

local references = request_current("textDocument/references", {
  textDocument = text_document_params(0),
  position = {
    line = 0,
    character = alpha_call_start,
  },
  context = {
    includeDeclaration = true,
  },
})

if type(references) ~= "table" or #references < 4 then
  fail("expected references for alpha across workspace files: " .. vim.inspect(references))
end

if not any_location_in_file(references, main_file) or not any_location_in_file(references, ref_file) then
  fail("reference results did not cover both workspace files: " .. vim.inspect(references))
end

vim.print({
  document_symbols = vim.tbl_map(function(symbol)
    return symbol.name
  end, document_symbols),
  workspace_symbol = alpha_workspace_symbol.name,
  definition = definition_uri,
  reference_count = #references,
  roxygen_action = roxygen_action.title,
})
