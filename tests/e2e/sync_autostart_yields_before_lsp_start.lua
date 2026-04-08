vim.opt.rtp:prepend(vim.fn.getcwd())

local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "r"

local ark = require("ark")
local lsp = require("ark.lsp")
local tmux = require("ark.tmux")

local original_lsp_start = lsp.start
local original_tmux_start = tmux.start

local setup_returned = false
local saw_inline_start = false
local start_calls = 0

lsp.start = function(...)
  start_calls = start_calls + 1
  if not setup_returned then
    saw_inline_start = true
  end
  return 1
end

tmux.start = function()
  return "%42", nil
end

local ok, err = pcall(function()
  ark.setup({
    auto_start_pane = true,
    auto_start_lsp = true,
    async_startup = false,
    configure_slime = false,
  })
  setup_returned = true

  if saw_inline_start then
    error("expected sync autostart to yield before lsp.start()", 0)
  end

  local started = vim.wait(1000, function()
    return start_calls == 1
  end, 20, false)

  if not started then
    error("timed out waiting for scheduled lsp.start()", 0)
  end
end)

lsp.start = original_lsp_start
tmux.start = original_tmux_start

if not ok then
  error(err, 0)
end
