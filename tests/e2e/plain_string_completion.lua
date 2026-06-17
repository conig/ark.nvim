local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_plain_string_completion.R"

local _, client = ark_test.setup_managed_buffer(test_file, {
  'stop("',
  'stop("")',
})

local trigger_characters = (((client.server_capabilities or {}).completionProvider or {}).triggerCharacters) or {}
if not vim.tbl_contains(trigger_characters, '"') then
  ark_test.fail('ark_lsp completion triggers missing double quote: ' .. vim.inspect(trigger_characters))
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

local function completion_at(line, column)
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
    context = {
      triggerKind = vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter,
      triggerCharacter = '"',
    },
  }, 10000))
end

local raw_items = completion_at(1, #lines[1])
if #raw_items ~= 0 then
  ark_test.fail('stop(" completion expected no generic string completions: ' .. vim.inspect(ark_test.item_labels(raw_items)))
end

-- Mirrors paired-quote editor setups where the cursor sits between the two
-- quotes immediately after typing the opening delimiter.
local paired_items = completion_at(2, assert(lines[2]:find('"', 1, true)))
if #paired_items ~= 0 then
  ark_test.fail('stop("") completion expected no generic string completions: ' .. vim.inspect(ark_test.item_labels(paired_items)))
end

vim.print({
  raw_stop = "ok",
  paired_stop = "ok",
})
