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
        buf = buf,
        filetype = vim.bo[buf].filetype,
        buftype = vim.bo[buf].buftype,
        zindex = config.zindex,
        relative = config.relative,
        anchor_win = config.win,
        row = config.row,
        col = config.col,
        width = config.width,
        height = config.height,
        lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(5, vim.api.nvim_buf_line_count(buf)), false),
      }
    end
  end
  table.sort(wins, function(a, b)
    return (a.zindex or 0) < (b.zindex or 0)
  end)
  return wins
end

local function absolute_position(float)
  if float.relative == "editor" then
    return {
      row = float.row,
      col = float.col,
    }
  end

  if float.relative == "win" and type(float.anchor_win) == "number" and float.anchor_win ~= 0 then
    local parent = vim.api.nvim_win_get_position(float.anchor_win)
    return {
      row = parent[1] + float.row,
      col = parent[2] + float.col,
    }
  end

  return nil
end

local function bounds(float)
  local pos = absolute_position(float)
  if not pos then
    return nil
  end

  return {
    top = pos.row,
    left = pos.col,
    bottom = pos.row + float.height,
    right = pos.col + float.width,
  }
end

local function overlaps(lhs, rhs)
  if not lhs or not rhs then
    return false
  end

  return lhs.left < rhs.right
    and rhs.left < lhs.right
    and lhs.top < rhs.bottom
    and rhs.top < lhs.bottom
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

-- Reproduce the reverse-order case: signature help is already visible for the
-- call, then package completion opens. The existing signature float must move
-- out of the way of the newly opened menu.
stop_insert_mode()
blink.hide()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "library(gg" })
vim.api.nvim_win_set_cursor(0, { 1, 10 })
vim.cmd("startinsert")
vim.lsp.buf.signature_help()

local sig_ready = vim.wait(3000, function()
  for _, float in ipairs(float_windows()) do
    local joined = table.concat(float.lines or {}, "\n")
    if joined:find("lib%.loc", 1, false) then
      return true
    end
  end
  return false
end, 50, false)

blink.show({
  providers = { "ark_lsp" },
})

local menu_ready = vim.wait(10000, function()
  if not blink.is_visible() then
    return false
  end
  for _, item in ipairs(list.items) do
    if item.label == "ggplot2" then
      return true
    end
  end
  return false
end, 50, false)

local result = {
  sig_ready = sig_ready,
  menu_ready = menu_ready,
  blink_visible = blink.is_visible(),
  blink_labels = vim.tbl_map(function(item)
    return item.label
  end, list.items),
  line = vim.api.nvim_get_current_line(),
  cursor = vim.api.nvim_win_get_cursor(0),
  mode = vim.fn.mode(),
  floats = float_windows(),
  status = current_status(),
}

blink.hide()
stop_insert_mode()

if not result.sig_ready or not result.menu_ready then
  ark_test.fail(vim.inspect(result))
end

local menu_float = nil
local signature_float = nil
for _, float in ipairs(result.floats) do
  if float.filetype == "blink-cmp-menu" then
    menu_float = float
  elseif float.filetype == "markdown" and table.concat(float.lines or {}, "\n"):find("lib%.loc", 1, false) then
    signature_float = float
  end
end

if not menu_float or not signature_float then
  ark_test.fail(vim.inspect(result))
end

local menu_bounds = bounds(menu_float)
local signature_bounds = bounds(signature_float)
if overlaps(menu_bounds, signature_bounds) then
  ark_test.fail(vim.inspect({
    error = "existing signature help overlaps newly opened completion menu",
    menu = menu_float,
    menu_bounds = menu_bounds,
    signature = signature_float,
    signature_bounds = signature_bounds,
    result = result,
  }))
end

vim.print({
  menu = menu_float,
  signature = signature_float,
  menu_bounds = menu_bounds,
  signature_bounds = signature_bounds,
})
