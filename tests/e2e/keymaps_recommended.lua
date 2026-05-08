vim.g.mapleader = " "

local sent = {}
local calls = {}
local pane_exists = false

package.loaded["ark"] = {
  send = function(text)
    sent[#sent + 1] = text
    return true, nil
  end,
  status = function()
    return { pane_exists = pane_exists }
  end,
  start_pane = function()
    calls.start_pane = (calls.start_pane or 0) + 1
    return "pane"
  end,
  restart_pane = function()
    calls.restart_pane = (calls.restart_pane or 0) + 1
    return "pane"
  end,
  refresh = function(bufnr)
    calls.refresh = (calls.refresh or 0) + 1
    calls.refresh_bufnr = bufnr
  end,
  new_tab = function()
    calls.new_tab = (calls.new_tab or 0) + 1
  end,
  prev_tab = function()
    calls.prev_tab = (calls.prev_tab or 0) + 1
  end,
  next_tab = function()
    calls.next_tab = (calls.next_tab or 0) + 1
  end,
  close_tab = function()
    calls.close_tab = (calls.close_tab or 0) + 1
  end,
  view = function(expr, bufnr)
    calls.view = { expr = expr, bufnr = bufnr }
  end,
  help = function(bufnr)
    calls.help = bufnr
  end,
  snippets = function(bufnr)
    calls.snippets = bufnr
  end,
  targets_pick = function(bufnr)
    calls.targets_pick = bufnr
  end,
  targets_active = function(bufnr)
    calls.targets_active = bufnr
    return "clean_data"
  end,
}

package.loaded["nvim-slimetree"] = {
  slimetree = {
    send_current = function(opts)
      calls.send_current = (calls.send_current or 0) + 1
      calls.send_current_opts = opts
    end,
    send_line = function()
      calls.send_line = (calls.send_line or 0) + 1
    end,
  },
}

vim.cmd("enew")
vim.bo.filetype = "r"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "mtcars" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })

local keymaps = require("ark.keymaps")
keymaps.setup({
  filetypes = { "r" },
  keymaps = {
    enabled = true,
    prefix = "<F5>",
    target_prefix = "<F7>",
    snippets = "<F6>",
  },
})

local function mapping(lhs, mode)
  local item = vim.fn.maparg(lhs, mode or "n", false, true)
  if type(item) ~= "table" or item.lhs == nil or item.lhs == "" then
    error("missing mapping for " .. lhs, 0)
  end
  return item
end

local function invoke(lhs, mode)
  local item = mapping(lhs, mode)
  if type(item.callback) ~= "function" then
    error("mapping for " .. lhs .. " does not have a Lua callback: " .. vim.inspect(item), 0)
  end
  item.callback()
end

invoke("<CR>")
if calls.send_current ~= 1 or calls.send_current_opts ~= nil then
  error("expected <CR> to send current form, got " .. vim.inspect(calls), 0)
end

invoke("<leader><CR>")
if calls.send_current ~= 2 or not (type(calls.send_current_opts) == "table" and calls.send_current_opts.hold_position == true) then
  error("expected <leader><CR> to send current form with hold_position, got " .. vim.inspect(calls), 0)
end

invoke("<C-c><C-c>")
if calls.send_line ~= 1 then
  error("expected <C-c><C-c> to send current line, got " .. vim.inspect(calls), 0)
end

local visual_cr = mapping("<CR>", "x")
if visual_cr.rhs ~= "<Plug>SlimeRegionSend" then
  error("expected visual <CR> to send selected region through vim-slime, got " .. vim.inspect(visual_cr), 0)
end

invoke("<F5>w")
if sent[#sent] ~= "mtcars" then
  error("expected <prefix>w to send expression under cursor, got " .. vim.inspect(sent), 0)
end

invoke("<F5>h")
if sent[#sent] ~= "head(mtcars)" then
  error("expected <prefix>h to send head(expr), got " .. vim.inspect(sent), 0)
end

invoke("<F5>s")
if sent[#sent] ~= "summary(mtcars)" then
  error("expected <prefix>s to send summary(expr), got " .. vim.inspect(sent), 0)
end

invoke("<F5>p")
if calls.start_pane ~= 1 or calls.refresh ~= 1 then
  error("expected <prefix>p to start pane and refresh, got " .. vim.inspect(calls), 0)
end

pane_exists = true
invoke("<F5>p")
if calls.restart_pane ~= 1 or calls.refresh ~= 2 then
  error("expected <prefix>p to restart existing pane and refresh, got " .. vim.inspect(calls), 0)
end

invoke("<F5>=")
invoke("<F5>[")
invoke("<F5>]")
invoke("<F5>-")
if calls.new_tab ~= 1 or calls.prev_tab ~= 1 or calls.next_tab ~= 1 or calls.close_tab ~= 1 then
  error("expected tab mappings to call Ark tab helpers, got " .. vim.inspect(calls), 0)
end

invoke("<F5>V")
invoke("<F5>?")
invoke("<F6>")
if not vim.deep_equal(calls.view, { expr = nil, bufnr = 0 }) or calls.help ~= 0 or calls.snippets ~= 0 then
  error("expected view/help/snippets mappings to call Ark helpers, got " .. vim.inspect(calls), 0)
end

invoke("<F7>ta")
invoke("<F7>tn")
if calls.targets_pick ~= 0 or calls.targets_active ~= 0 then
  error("expected target mappings to call Ark target helpers, got " .. vim.inspect(calls), 0)
end
