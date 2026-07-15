local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function request(client, method, params, timeout_ms)
  return ark_test.request(client, method, params, timeout_ms or 5000)
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/workspace-indexing-background")
local ignored = root .. "/generated"
vim.fn.mkdir(ignored, "p")
vim.fn.writefile({ "generated/" }, root .. "/.gitignore")

-- This tree is deliberately large enough to expose a synchronous traversal,
-- while the ignore-aware walker should reject it at the directory boundary.
for directory = 1, 100 do
  local path = string.format("%s/%03d", ignored, directory)
  vim.fn.mkdir(path, "p")
  for file = 1, 100 do
    local handle, open_error = vim.uv.fs_open(string.format("%s/%03d.R", path, file), "w", 384)
    if not handle then
      fail("failed to create ignored fixture: " .. tostring(open_error))
    end
    vim.uv.fs_close(handle)
  end
end

local helper_file = root .. "/helper.R"
local main_file = root .. "/main.R"
vim.fn.writefile({
  "background_helper <- function(value) {",
  "  value + 1",
  "}",
}, helper_file)
vim.fn.writefile({ "result <- background_helper(1)" }, main_file)

vim.cmd("edit " .. vim.fn.fnameescape(main_file))
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

local started = vim.uv.hrtime()
require("ark").start_lsp(0)
ark_test.wait_for("ark lsp client", 5000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)
local initialized_ms = (vim.uv.hrtime() - started) / 1e6
if initialized_ms > 1000 then
  fail(string.format("LSP initialization blocked on ignored workspace traversal: %.1fms", initialized_ms))
end

local client = current_client()
local symbols = request(client, "textDocument/documentSymbol", {
  textDocument = vim.lsp.util.make_text_document_params(0),
})
if type(symbols) ~= "table" or vim.tbl_isempty(symbols) then
  fail("current-buffer static symbols were unavailable during background indexing")
end

local call_start = assert(vim.api.nvim_get_current_line():find("background_helper", 1, true)) - 1
local definition_uri = nil
ark_test.wait_for("background workspace index", 10000, function()
  local definition = request(client, "textDocument/definition", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = 0, character = call_start },
  })
  if type(definition) == "table" and definition[1] then
    definition_uri = definition[1].targetUri or definition[1].uri
  end
  return type(definition_uri) == "string"
    and vim.fs.normalize(vim.uri_to_fname(definition_uri)) == vim.fs.normalize(helper_file)
end)

vim.print({
  initialized_ms = initialized_ms,
  definition = definition_uri,
})
