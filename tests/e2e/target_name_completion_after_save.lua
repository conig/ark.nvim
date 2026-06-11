local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function open_file(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
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

local function completion_labels()
  local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
  local result = request_current("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = {
      line = 0,
      character = #line,
    },
    context = {
      triggerKind = vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter,
      triggerCharacter = "(",
    },
  }, 10000)

  return ark_test.item_labels(ark_test.completion_items(result))
end

local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/target-name-completion-after-save")
local pipeline_dir = root .. "/_target_pipelines"
vim.fn.mkdir(pipeline_dir, "p")

local targets_file = root .. "/_targets.R"
local pipeline_file = pipeline_dir .. "/renamed_target.R"
local analysis_file = root .. "/analysis.R"

vim.fn.writefile({
  "targets::tar_source(\"_target_pipelines\")",
}, targets_file)
vim.fn.writefile({
  "targets::tar_target(old_target_name, 1)",
}, pipeline_file)
vim.fn.writefile({
  "tar_load(",
}, analysis_file)

open_file(targets_file)
start_lsp_for_current_buffer()

open_file(analysis_file)
start_lsp_for_current_buffer()

local initial_labels = completion_labels()
if not contains(initial_labels, "old_target_name") then
  fail("initial target completion missing old target: " .. vim.inspect(initial_labels))
end

open_file(pipeline_file)
start_lsp_for_current_buffer()

-- Regression: after renaming a target in an open sourced pipeline file and
-- saving it, target-name completion should use the saved name, not a stale
-- name reintroduced by the related _targets.R disk reindex.
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "targets::tar_target(new_target_name, 1)",
})
vim.cmd("write")

open_file(analysis_file)
local labels = nil
local refreshed = vim.wait(2500, function()
  labels = completion_labels()
  return contains(labels, "new_target_name")
end, 100, false)

if not refreshed then
  fail("renamed target completion never appeared after save: " .. vim.inspect(labels))
end
if contains(labels, "old_target_name") then
  fail("renamed target completion still included old target after save: " .. vim.inspect(labels))
end

vim.print({
  targets = labels,
})
