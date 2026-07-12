local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/large-file-edit-diagnostics")
vim.fn.mkdir(root, "p")
local path = root .. "/large.R"
local lines = {}
for i = 1, 5000 do
  lines[i] = string.format("value_%d <- %d + 1", i, i)
end
vim.fn.writefile(lines, path)

vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.cmd("setfiletype r")

-- Measure the complete editor-facing path: buffer edit, Neovim change
-- notification, Ark parse/index/diagnostics work, and publishDiagnostics back
-- to the editor. Capturing the real notification also lets us distinguish an
-- empty initial publication from the publication caused by the timed edit.
local publications = {}
local original_publish_handler = vim.lsp.handlers["textDocument/publishDiagnostics"]
vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
  if result and result.uri == vim.uri_from_bufnr(0) then
    table.insert(publications, vim.deepcopy(result))
  end
  if original_publish_handler then
    return original_publish_handler(err, result, ctx, config)
  end
end

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)
require("ark").start_lsp(0)

ark_test.wait_for("initialized Ark LSP", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

ark_test.wait_for("initial large-file diagnostics publication", 15000, function()
  return #publications > 0
end)

local initial_publications = #publications
local last_line = #lines - 1
local started = vim.uv.hrtime()
vim.api.nvim_buf_set_lines(0, last_line, last_line + 1, false, { "broken <- function(" })

local matching_diagnostic = nil
ark_test.wait_for("large-file edit diagnostics", 15000, function()
  for i = initial_publications + 1, #publications do
    for _, diagnostic in ipairs(publications[i].diagnostics or {}) do
      if diagnostic.range and diagnostic.range.start and diagnostic.range.start.line == last_line then
        matching_diagnostic = diagnostic
        return true
      end
    end
  end
  return false
end)

local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
local budget_ms = tonumber(vim.env.ARK_LARGE_FILE_DIAGNOSTICS_BUDGET_MS) or 2000

vim.lsp.handlers["textDocument/publishDiagnostics"] = original_publish_handler

if elapsed_ms > budget_ms then
  fail(vim.inspect({
    error = "large-file edit diagnostics exceeded latency budget",
    elapsed_ms = elapsed_ms,
    budget_ms = budget_ms,
    bytes = vim.fn.getfsize(path),
    lines = #lines,
    diagnostic = matching_diagnostic,
  }))
end

vim.print({
  event = "diagnostics.large_file_edit",
  elapsed_ms = elapsed_ms,
  budget_ms = budget_ms,
  bytes = vim.fn.getfsize(path),
  lines = #lines,
})
