local function fail(message)
  error(message, 0)
end

local function wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    fail("timed out waiting for " .. label)
  end
end

local function diagnostic_messages()
  local diagnostics = vim.diagnostic.get(0)
  local messages = {}

  for _, diagnostic in ipairs(diagnostics) do
    messages[#messages + 1] = diagnostic.message
  end

  return messages
end

local function any_message_contains(messages, needle)
  for _, message in ipairs(messages) do
    if message:find(needle, 1, true) then
      return true
    end
  end

  return false
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  configure_slime = true,
})

local test_file = "/tmp/ark_qmd_diagnostics.qmd"

vim.fn.writefile({
  "---",
  'title: "Ark Quarto diagnostics"',
  "format:",
  "  revealjs:",
  "    theme: default",
  "---",
  "",
  '<section class="summary">',
  "  <p>This markup mentions undefined_symbol_in_markup and library().</p>",
  "</section>",
  "",
  "```{python}",
  "undefined_symbol_in_python = library()",
  "```",
  "",
  "```{r setup, include=FALSE}",
  "known_value <- 1",
  "```",
  "",
  '```{r plot-label, fig.alt="Synthetic figure description", fig.width=7}',
  "known_value",
  "undefined_symbol_in_qmd_chunk",
  "```",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype quarto")

wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

require("ark").refresh(0)

wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true
end)

-- Quarto decks commonly mix front matter, HTML fragments, non-R fences, and
-- chunk options. Only executable R chunks should be linted as R code.
wait_for("qmd diagnostics", 10000, function()
  return #vim.diagnostic.get(0) >= 1
end)

vim.wait(500, function()
  return false
end, 500, false)

local diagnostics = vim.diagnostic.get(0)
local messages = diagnostic_messages()

if #diagnostics ~= 1 then
  fail("expected exactly one diagnostic from the QMD R chunk, got: " .. vim.inspect(diagnostics))
end

if not any_message_contains(messages, "No symbol named 'undefined_symbol_in_qmd_chunk' in scope.") then
  fail("expected QMD R chunk diagnostic, got: " .. vim.inspect(messages))
end

if any_message_contains(messages, "undefined_symbol_in_markup") then
  fail("unexpected markup diagnostic: " .. vim.inspect(messages))
end

if any_message_contains(messages, "undefined_symbol_in_python") then
  fail("unexpected non-R chunk diagnostic: " .. vim.inspect(messages))
end

if any_message_contains(messages, "No symbol named 'library' in scope.") then
  fail("unexpected library() diagnostic in mixed QMD document: " .. vim.inspect(messages))
end

vim.print({
  diagnostics = messages,
})
