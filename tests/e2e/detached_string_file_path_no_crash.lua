local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_detached_string_file_path_no_crash.R"

-- Reproduce detached plain-string completion at the exact user-reported shape:
-- typing `".R"` in an R buffer. Detached ark-lsp must not route this through
-- local R-backed path normalization, because that aborts the process.
local client = select(2, ark_test.setup_managed_buffer(test_file, {
  '".R"',
}))

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function completion_result_at(line, column)
  local active = current_client()
  if not active or active:is_stopped() then
    ark_test.fail("ark_lsp stopped before completion request")
  end

  local response, err = active:request_sync("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }, 10000, 0)

  return active, response, err
end

local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
local after_r_column = assert(line:find('.R"', 1, true)) + 1

local active, response, err = completion_result_at(1, after_r_column)
if err then
  ark_test.fail('detached file-path completion errored for `".R"`: ' .. err)
end

if not response then
  ark_test.fail('missing detached file-path completion response for `".R"`')
end

if response.error or response.err then
  ark_test.fail('unexpected detached file-path completion error for `".R"`: ' .. vim.inspect(response))
end

if active:is_stopped() then
  ark_test.fail('ark_lsp stopped after detached file-path completion for `".R"`')
end

local items = ark_test.completion_items(response.result)

vim.print({
  completion_items = #items,
  client_stopped = active:is_stopped(),
})
