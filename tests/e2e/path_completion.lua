local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_root = vim.fs.normalize(vim.fn.tempname())
local src_dir = test_root .. "/src"
local test_file = test_root .. "/analysis.R"
local sentinel = "path-completion-sentinel.R"

vim.fn.mkdir(src_dir, "p")
vim.fn.writefile({ "# sentinel" }, src_dir .. "/" .. sentinel)
vim.fn.writefile({ "# sibling" }, src_dir .. "/other.R")

local _, client = ark_test.setup_managed_buffer(test_file, {
  'source("src/")',
  "1 / 2",
})

local trigger_characters = (((client.server_capabilities or {}).completionProvider or {}).triggerCharacters) or {}
if not vim.tbl_contains(trigger_characters, "/") then
  ark_test.fail("ark_lsp completion triggers missing slash for path completion: " .. vim.inspect(trigger_characters))
end

local function completion_items_at(line_number, column, trigger)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line_number - 1, character = column },
  }

  if trigger then
    params.context = {
      triggerKind = vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter,
      triggerCharacter = trigger,
    }
  end

  local response, err = client:request_sync("textDocument/completion", params, 10000, 0)
  if err then
    ark_test.fail("path completion request errored: " .. err)
  end

  if not response then
    ark_test.fail("path completion request returned no response")
  end

  if response.error or response.err then
    ark_test.fail("path completion response contained an error: " .. vim.inspect(response))
  end

  return ark_test.completion_items(response.result)
end

local path_line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
local after_path_slash_column = assert(path_line:find('/"', 1, true))

-- Direct LSP completion inside a quoted relative path should list files from
-- the buffer's workspace root, even when Neovim was started from another cwd.
local manual_items = completion_items_at(1, after_path_slash_column)
if not ark_test.find_item(manual_items, sentinel) then
  ark_test.fail('manual path completion inside "src/" missing sentinel: ' .. vim.inspect(ark_test.item_labels(manual_items)))
end

-- Typing a slash inside a string should be enough for Ark to offer path items.
local slash_items = completion_items_at(1, after_path_slash_column, "/")
if not ark_test.find_item(slash_items, sentinel) then
  ark_test.fail('slash-triggered path completion inside "src/" missing sentinel: ' .. vim.inspect(ark_test.item_labels(slash_items)))
end

-- The slash trigger must remain path-specific; ordinary division should not
-- open the generic completion menu.
local division_line = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
local after_division_slash_column = assert(division_line:find("/", 1, true))
local division_items = completion_items_at(2, after_division_slash_column, "/")
if #division_items ~= 0 then
  ark_test.fail("division slash unexpectedly returned completions: " .. vim.inspect(ark_test.item_labels(division_items)))
end

vim.print({
  manual_items = ark_test.item_labels(manual_items),
  slash_items = ark_test.item_labels(slash_items),
  division_items = ark_test.item_labels(division_items),
})
