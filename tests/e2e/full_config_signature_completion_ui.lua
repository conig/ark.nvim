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
        lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(6, vim.api.nvim_buf_line_count(buf)), false),
      }
    end
  end
  table.sort(wins, function(a, b)
    return (a.zindex or 0) < (b.zindex or 0)
  end)
  return wins
end

local function close_float_windows()
  for _, float in ipairs(float_windows()) do
    if vim.api.nvim_win_is_valid(float.win) then
      pcall(vim.api.nvim_win_close, float.win, true)
    end
  end
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

local function joined_lines(float)
  return table.concat(float.lines or {}, "\n")
end

local function find_float(floats, predicate)
  for _, float in ipairs(floats) do
    if predicate(float) then
      return float
    end
  end
end

local function completion_has(label)
  if not blink.is_visible() then
    return false
  end
  for _, item in ipairs(list.items) do
    if item.label == label then
      return true
    end
  end
  return false
end

local function wait_for_completion(label)
  return vim.wait(10000, function()
    return completion_has(label)
  end, 50, false)
end

local function wait_for_float(label, predicate)
  return vim.wait(3000, function()
    return find_float(float_windows(), predicate) ~= nil
  end, 50, false)
end

local function reset_buffer(lines, cursor)
  blink.hide()
  stop_insert_mode()
  close_float_windows()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, cursor)
end

local function result_for(name, extra)
  return vim.tbl_extend("force", {
    name = name,
    blink_visible = blink.is_visible(),
    blink_labels = vim.tbl_map(function(item)
      return item.label
    end, list.items),
    line = vim.api.nvim_get_current_line(),
    cursor = vim.api.nvim_win_get_cursor(0),
    mode = vim.fn.mode(),
    floats = float_windows(),
    status = current_status(),
  }, extra or {})
end

local function assert_no_overlap(name, menu_float, signature_float, result)
  if not menu_float or not signature_float then
    ark_test.fail(vim.inspect(result))
  end

  local menu_bounds = bounds(menu_float)
  local signature_bounds = bounds(signature_float)
  if overlaps(menu_bounds, signature_bounds) then
    ark_test.fail(vim.inspect({
      error = name .. " overlaps completion menu and signature help",
      menu = menu_float,
      menu_bounds = menu_bounds,
      signature = signature_float,
      signature_bounds = signature_bounds,
      result = result,
    }))
  end
end

local function assert_no_docs_float(name, result)
  local docs_float = find_float(result.floats, function(float)
    return float.filetype == "blink-cmp-documentation"
  end)
  if docs_float ~= nil then
    ark_test.fail(vim.inspect({
      error = name .. " left blink documentation open while signature help was visible",
      docs = docs_float,
      result = result,
    }))
  end
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

local results = {}

reset_buffer({ "library(gg" }, { 1, 10 })
vim.cmd("startinsert")
blink.show({
  providers = { "ark_lsp" },
})

local menu_ready = wait_for_completion("ggplot2")
vim.lsp.buf.signature_help()
local sig_ready = wait_for_float("library signature help", function(float)
  return joined_lines(float):find("lib%.loc", 1, false) ~= nil
end)

local result = result_for("completion_then_signature_no_overlap", {
  menu_ready = menu_ready,
  sig_ready = sig_ready,
})
results[#results + 1] = result
if not menu_ready or not sig_ready then
  ark_test.fail(vim.inspect(result))
end
assert_no_overlap(
  result.name,
  find_float(result.floats, function(float)
    return float.filetype == "blink-cmp-menu"
  end),
  find_float(result.floats, function(float)
    return float.filetype == "markdown" and joined_lines(float):find("lib%.loc", 1, false)
  end),
  result
)

reset_buffer({ "library(gg" }, { 1, 10 })
vim.cmd("startinsert")
vim.lsp.buf.signature_help()

sig_ready = wait_for_float("existing library signature help", function(float)
  return joined_lines(float):find("lib%.loc", 1, false) ~= nil
end)
blink.show({
  providers = { "ark_lsp" },
})
menu_ready = wait_for_completion("ggplot2")

result = result_for("signature_then_completion_repositions", {
  sig_ready = sig_ready,
  menu_ready = menu_ready,
})
results[#results + 1] = result
if not sig_ready or not menu_ready then
  ark_test.fail(vim.inspect(result))
end
assert_no_overlap(
  result.name,
  find_float(result.floats, function(float)
    return float.filetype == "blink-cmp-menu"
  end),
  find_float(result.floats, function(float)
    return float.filetype == "markdown" and joined_lines(float):find("lib%.loc", 1, false)
  end),
  result
)

reset_buffer({ "libr" }, { 1, 4 })
vim.cmd("startinsert")
blink.show({ providers = { "ark_lsp" } })

menu_ready = wait_for_completion("library")
local docs_ready = wait_for_float("library blink docs", function(float)
  return float.filetype == "blink-cmp-documentation"
end)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "library(" })
vim.api.nvim_win_set_cursor(0, { 1, 8 })
vim.lsp.buf.signature_help()
sig_ready = wait_for_float("library call signature help", function(float)
  return float.filetype == "markdown"
end)

result = result_for("library_docs_hidden_by_signature", {
  menu_ready = menu_ready,
  docs_ready = docs_ready,
  sig_ready = sig_ready,
})
results[#results + 1] = result
if not menu_ready or not docs_ready or not sig_ready then
  ark_test.fail(vim.inspect(result))
end
assert_no_docs_float(result.name, result)

reset_buffer({ "read.ta" }, { 1, 7 })
vim.cmd("startinsert")
blink.show({
  providers = { "ark_lsp" },
})

menu_ready = wait_for_completion("read.table")
docs_ready = wait_for_float("read.table blink docs", function(float)
  return float.filetype == "blink-cmp-documentation"
end)

vim.api.nvim_buf_set_lines(0, 0, -1, false, { "read.table(" })
vim.api.nvim_win_set_cursor(0, { 1, 11 })
blink.show({
  providers = { "ark_lsp" },
})
vim.lsp.buf.signature_help()

sig_ready = wait_for_float("read.table signature help", function(float)
  return float.filetype == "markdown" and joined_lines(float):find("read%.table%(", 1, false)
end)

result = result_for("function_docs_hidden_and_no_overlap", {
  menu_ready = menu_ready,
  docs_ready = docs_ready,
  sig_ready = sig_ready,
})
results[#results + 1] = result
if not menu_ready or not docs_ready or not sig_ready then
  ark_test.fail(vim.inspect(result))
end
assert_no_docs_float(result.name, result)
assert_no_overlap(
  result.name,
  find_float(result.floats, function(float)
    return float.filetype == "blink-cmp-menu"
  end),
  find_float(result.floats, function(float)
    return float.filetype == "markdown" and joined_lines(float):find("read%.table%(", 1, false)
  end),
  result
)

blink.hide()
stop_insert_mode()
close_float_windows()

vim.print({
  results = results,
})
