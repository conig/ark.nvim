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

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/target-definition")
vim.fn.mkdir(root, "p")

local targets_file = root .. "/_targets.R"
local analysis_file = root .. "/analysis.R"

vim.fn.writefile({
  "list(",
  "  tar_target(brief_intervention_summary, raw_data + 1)",
  ")",
}, targets_file)

vim.fn.writefile({
  "brief_intervention_summary <- tar_read(brief_intervention_summary)",
  "brief_intervention_summary",
}, analysis_file)

open_file(targets_file)
start_lsp_for_current_buffer()

open_file(analysis_file)
start_lsp_for_current_buffer()

local ref_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
local target_start = assert(ref_line:find("brief_intervention_summary%)", 1)) - 1

local definition = request_current("textDocument/definition", {
  textDocument = text_document_params(0),
  position = {
    line = 0,
    character = target_start,
  },
})

if type(definition) ~= "table" or vim.tbl_isempty(definition) then
  fail("expected target definition result: " .. vim.inspect(definition))
end

local definition_target = definition[1]
local definition_uri = definition_target.targetUri or definition_target.uri
if vim.fs.normalize(vim.uri_to_fname(definition_uri)) ~= vim.fs.normalize(targets_file) then
  fail("target definition resolved to unexpected file: " .. vim.inspect(definition))
end

vim.print({
  definition = definition_uri,
})
