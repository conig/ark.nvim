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

local function current_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/targets-diagnostics-after-targets-edit")
vim.fn.mkdir(root .. "/.git", "p")

local targets_file = root .. "/_targets.R"
local analysis_file = root .. "/analysis.R"

vim.fn.writefile({
  "list(",
  "  targets::tar_target(existing_target, 1)",
  ")",
}, targets_file)

vim.fn.writefile({
  "new_target",
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
  local client = current_client(bufnr)
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

ark_test.wait_for("initial missing target diagnostic", 10000, function()
  return contains(diagnostic_messages(bufnr), "No symbol named 'new_target' in scope.")
end)

-- This mirrors adding a target after the managed R session and detached LSP are
-- already running. The next edit in another R buffer must make diagnostics
-- catch up with the updated targets script instead of using a stale index.
vim.fn.writefile({
  "list(",
  "  targets::tar_target(existing_target, 1),",
  "  targets::tar_target(new_target, existing_target + 1)",
  ")",
}, targets_file)

vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "new_target " })

local refreshed = vim.wait(10000, function()
  return not contains(diagnostic_messages(bufnr), "No symbol named 'new_target' in scope.")
end, 100, false)

local final_messages = diagnostic_messages(bufnr)
if not refreshed then
  error(vim.inspect({
    final_diagnostics = final_messages,
    status = require("ark").status({ include_lsp = true }, bufnr),
  }), 0)
end

vim.print({
  diagnostics = final_messages,
})
