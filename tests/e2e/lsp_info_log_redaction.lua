local ark_test = require("ark_test")

local function fail(message)
  error(message, 0)
end

vim.opt.rtp:prepend(vim.fn.getcwd())

-- Capture the real server-to-editor INFO channel. This protects source text
-- from being copied into Neovim's LSP logs by notification, request, or
-- completion-context diagnostics.
local info_messages = {}
local original_log_handler = vim.lsp.handlers["window/logMessage"]
vim.lsp.handlers["window/logMessage"] = function(_, result)
  if result and result.type == vim.lsp.protocol.MessageType.Info then
    table.insert(info_messages, result.message or "")
  end
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/lsp-info-log-redaction")
vim.fn.mkdir(root, "p")
local path = root .. "/private.R"
local open_marker = "ARK_PRIVATE_OPEN_PAYLOAD_93cf62"
local change_marker = "ARK_PRIVATE_CHANGE_PAYLOAD_41d8ab"
vim.fn.writefile({ open_marker .. " <- 1", "candidate <- 1" }, path)

vim.cmd("edit " .. vim.fn.fnameescape(path))
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)
require("ark").start_lsp(0)

ark_test.wait_for("initialized Ark LSP", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

vim.diagnostic.reset(nil, 0)
vim.api.nvim_buf_set_lines(0, 1, 2, false, { "candidate <- (" .. change_marker })

-- Neovim batches text changes before notifying the server. Wait for that real
-- diagnostic publication rather than allowing the following request to race
-- the client-side debounce timer.
ark_test.wait_for("didChange diagnostic", 5000, function()
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    if diagnostic.lnum == 1 then
      return true
    end
  end
  return false
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
if not client then
  fail("Ark LSP client disappeared before the completion request")
end

ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = {
    line = 1,
    character = #(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] or ""),
  },
  context = {
    triggerKind = 1,
  },
}, 10000)

vim.lsp.handlers["window/logMessage"] = original_log_handler

for _, message in ipairs(info_messages) do
  if message:find(open_marker, 1, true) or message:find(change_marker, 1, true) then
    fail("Ark INFO logs exposed editor source text: " .. message)
  end
end
