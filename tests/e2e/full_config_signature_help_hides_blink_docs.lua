local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  ark_test.fail("blink.cmp is required for this test")
end

local list = require("blink.cmp.completion.list")

local function current_client()
  return vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
end

local function current_status()
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end
  return ark.status({ include_lsp = true })
end

local function stop_insert_mode()
  if vim.fn.mode() == "i" then
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    ark_test.wait_for("normal mode", 4000, function()
      return vim.fn.mode() == "n"
    end)
  end
end

local function float_windows()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative and config.relative ~= "" then
      local buf = vim.api.nvim_win_get_buf(win)
      wins[#wins + 1] = {
        win = win,
        filetype = vim.bo[buf].filetype,
        relative = config.relative,
        anchor_win = config.win,
        row = config.row,
        col = config.col,
        width = config.width,
        height = config.height,
        lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(4, vim.api.nvim_buf_line_count(buf)), false),
      }
    end
  end
  return wins
end

ark_test.wait_for("R filetype", 10000, function()
  return vim.bo.filetype == "r"
end)

ark_test.wait_for("ark plugin load", 15000, function()
  return package.loaded["ark"] ~= nil
end)

ark_test.wait_for("ark bridge ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 30000, function()
  local status = current_status()
  return status ~= nil and status.repl_ready == true
end)

ark_test.wait_for("ark lsp client", 30000, function()
  local client = current_client()
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

ark_test.wait_for("ark lsp hydrated", 30000, function()
  local status = current_status()
  local lsp_status = status and status.lsp_status or nil
  return lsp_status
    and lsp_status.available == true
    and tonumber(lsp_status.consoleScopeCount or 0) > 0
    and tonumber(lsp_status.libraryPathCount or 0) > 0
end)

-- Reproduce the user's `library(` collision: Blink still has the `library`
-- completion docs open, then LSP signature help opens for the function call.
-- The Blink docs must get out of the way instead of stacking with signature help.
stop_insert_mode()
blink.hide()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "libr" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.cmd("startinsert")
blink.show({ providers = { "ark_lsp" } })

local menu_ready = vim.wait(10000, function()
  if not blink.is_visible() then
    return false
  end
  for _, item in ipairs(list.items) do
    if item.label == "library" then
      return true
    end
  end
  return false
end, 50, false)

local docs_ready = vim.wait(3000, function()
  for _, float in ipairs(float_windows()) do
    if float.filetype == "blink-cmp-documentation" then
      return true
    end
  end
  return false
end, 50, false)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "library(" })
vim.api.nvim_win_set_cursor(0, { 1, 8 })
vim.lsp.buf.signature_help()

local sig_ready = vim.wait(3000, function()
  for _, float in ipairs(float_windows()) do
    if float.filetype == "markdown" then
      return true
    end
  end
  return false
end, 50, false)

local result = {
  menu_ready = menu_ready,
  docs_ready = docs_ready,
  sig_ready = sig_ready,
  line = vim.api.nvim_get_current_line(),
  cursor = vim.api.nvim_win_get_cursor(0),
  mode = vim.fn.mode(),
  floats = float_windows(),
}

blink.hide()
stop_insert_mode()

if not result.menu_ready or not result.docs_ready or not result.sig_ready then
  ark_test.fail(vim.inspect(result))
end

for _, float in ipairs(result.floats) do
  if float.filetype == "blink-cmp-documentation" then
    ark_test.fail(vim.inspect({
      error = "blink documentation remained open while signature help was visible",
      result = result,
    }))
  end
end

vim.print(result)
