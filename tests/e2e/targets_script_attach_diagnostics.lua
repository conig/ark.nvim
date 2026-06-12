local ark_test = require("ark_test")

local function diagnostic_messages(bufnr)
  local messages = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    messages[#messages + 1] = diagnostic.message
  end
  table.sort(messages)
  return messages
end

local function contains(messages, needle)
  for _, message in ipairs(messages) do
    if message == needle then
      return true
    end
  end
  return false
end

local has_tarchetypes = vim.fn.system({ "Rscript", "-e", "cat(requireNamespace('tarchetypes', quietly = TRUE))" })
if vim.v.shell_error ~= 0 or has_tarchetypes:find("TRUE", 1, true) == nil then
  print("skipping targets_script_attach_diagnostics: tarchetypes is not installed")
  return
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/targets-script-attach-diagnostics")
vim.fn.mkdir(root .. "/.git", "p")

local targets_file = root .. "/pipeline_main.R"
local analysis_file = root .. "/_target_pipelines/analysis_targets.R"

vim.fn.mkdir(root .. "/_target_pipelines", "p")
vim.fn.writefile({
  "main:",
  "  script: pipeline_main.R",
}, root .. "/_targets.yaml")
vim.fn.writefile({
  "library(tarchetypes)",
}, targets_file)
vim.fn.writefile({
  "tar_map()",
  "undefined_symbol_ark",
}, analysis_file)

vim.cmd("edit " .. vim.fn.fnameescape(analysis_file))
vim.cmd("setfiletype r")
local bufnr = vim.api.nvim_get_current_buf()

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  error(pane_err or "failed to start managed pane", 0)
end

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

local lsp_config = require("ark").lsp_config(bufnr)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(bufnr)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

ark_test.wait_for("configured targets-script attach diagnostics", 10000, function()
  local messages = diagnostic_messages(bufnr)
  return contains(messages, "No symbol named 'undefined_symbol_ark' in scope.")
    and not contains(messages, "No symbol named 'tar_map' in scope.")
end)

local messages = diagnostic_messages(bufnr)
if contains(messages, "No symbol named 'tar_map' in scope.") then
  error("unexpected tar_map diagnostic: " .. vim.inspect(messages), 0)
end

vim.print({
  diagnostics = messages,
})
