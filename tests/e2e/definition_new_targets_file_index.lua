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

local function definition_uri_at(line, character, timeout_ms)
  local definition = request_current("textDocument/definition", {
    textDocument = text_document_params(0),
    position = {
      line = line,
      character = character,
    },
  }, timeout_ms or 10000)

  if type(definition) ~= "table" or vim.tbl_isempty(definition) then
    return nil
  end

  return definition[1] and (definition[1].targetUri or definition[1].uri) or nil
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/definition-new-targets-file-index")
local pipeline_dir = root .. "/_target_pipelines"
vim.fn.mkdir(pipeline_dir, "p")

local targets_file = root .. "/_targets.R"
local helper_file = pipeline_dir .. "/fresh_helper.R"

vim.fn.writefile({
  "targets::tar_source(\"_target_pipelines\")",
  "",
  "list(",
  "  tar_target(later_target, fresh_helper(raw_data))",
  ")",
}, targets_file)

open_file(targets_file)
start_lsp_for_current_buffer()

ark_test.wait_for("R file watch registration", 5000, function()
  local client = current_client()
  local dynamic_capabilities = client and client.dynamic_capabilities
  return dynamic_capabilities and dynamic_capabilities:get("workspace/didChangeWatchedFiles")
end)

local target_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local call_line = nil
local call_start = nil
for index, line in ipairs(target_lines) do
  local found = line:find("fresh_helper", 1, true)
  if found then
    call_line = index - 1
    call_start = found - 1
    break
  end
end

if call_line == nil then
  fail("failed to find fresh_helper call")
end

-- Regression: files added under a targets-sourced pipeline directory after
-- LSP startup must be ingested without restarting Neovim or changing
-- _targets.R.
vim.fn.writefile({
  "fresh_helper <- function(value) {",
  "  value",
  "}",
}, helper_file)

vim.wait(2000, function()
  return false
end, 100, false)

local definition_uri = definition_uri_at(call_line, call_start, 5000)
if type(definition_uri) ~= "string" or vim.fs.normalize(vim.uri_to_fname(definition_uri)) ~= vim.fs.normalize(helper_file) then
  fail("definition did not resolve to newly added targets helper file: " .. vim.inspect(definition_uri))
end

vim.print({
  definition = definition_uri,
})
