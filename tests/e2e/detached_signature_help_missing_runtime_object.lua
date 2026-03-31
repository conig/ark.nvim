local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_detached_signature_help_missing_runtime_object.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  "ggplot(mtcars, aes(",
})

local response, err = client:request_sync("textDocument/signatureHelp", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = {
    line = 0,
    character = #"ggplot(mtcars, aes(",
  },
}, 10000, 0)

if err then
  ark_test.fail("signature help errored for missing runtime object: " .. err)
end

if not response then
  ark_test.fail("missing signature help response")
end

if response.error or response.err then
  ark_test.fail("signature help returned unexpected error: " .. vim.inspect(response))
end

if response.result ~= nil then
  ark_test.fail("expected missing runtime object to degrade to nil signature help: " .. vim.inspect(response.result))
end

vim.print({
  signature_help = vim.NIL,
})
