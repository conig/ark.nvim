local ark_test = require("ark_test")

-- Realistic editor shapes: the closing delimiters are already inserted, and
-- completion is requested before them, including with an empty prefix.
require("ark").setup({ auto_start_pane = false, auto_start_lsp = false, async_startup = false })
local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/target-interaction-completion")
vim.fn.mkdir(root, "p")
vim.fn.writefile({
  "list(targets::tar_target(analysis_data, 1), targets::tar_target(analysis_model, 2))",
}, root .. "/_targets.R")
local cases = {
  "tar_load(analysis_|)",
  "tar_make(analysis_|)",
  "tar_load(|)",
  "tar_make(|)",
  "tar_load(c(|))",
  "tar_load(c(analysis_data, c(|)))",
  'targets::tar_make(names = c("analysis_|"))',
  "tar_make(names = |)",
  "targets::tar_make(names = analysis_|)",
  'tar_load("analysis_|")',
  "tar_load(c(analysis_|))",
  "tar_make(names = c(analysis_data, analysis_|))",
  "tar_make(names = c(analysis_data, |))",
  "tar_delete(|)",
  "tar_meta(names = |)",
  "tar_progress(names = |)",
  "tar_read(analysis_|)",
  "tar_invalidate(analysis_|)",
  "tar_delete(analysis_|)",
  "tar_meta(names = analysis_|)",
  "tar_progress(names = analysis_|)",
}
local lines, columns = {}, {}
for index, case in ipairs(cases) do
  columns[index] = assert(case:find("|", 1, true)) - 1
  lines[index] = case:gsub("|", "")
end
vim.fn.writefile(lines, root .. "/analysis.R")
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/analysis.R"))
vim.cmd("setfiletype r")
local config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(config.cmd[1])
require("ark").start_lsp(0)
ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client and client.initialized
end)
local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
local function items_at(index)
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = index - 1, character = columns[index] },
    context = { triggerKind = 1 },
  }, 10000))
end
ark_test.wait_for("indexed target names", 10000, function()
  return ark_test.find_item(items_at(1), "analysis_data") ~= nil
end)
local failures = {}
for index, case in ipairs(cases) do
  local items = items_at(index)
  for _, name in ipairs({ "analysis_data", "analysis_model" }) do
    local item = ark_test.find_item(items, name)
    if not item or item.detail ~= "targets target" then
      failures[#failures + 1] = case .. " missing target " .. name
    elseif (ark_test.insert_text(item) or item.label) ~= name then
      failures[#failures + 1] = case .. " incorrect insertion: " .. vim.inspect(item)
    end
  end
end
assert(#failures == 0, table.concat(failures, "\n"))
vim.print({ completed = #cases })
