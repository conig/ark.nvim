vim.opt.rtp:prepend(vim.fn.getcwd())

local picker_spec = nil
local vim_snippet_expanded = nil
local luasnip_expanded = nil

local original_snippet_expand = vim.snippet and vim.snippet.expand or nil
if type(vim.snippet) ~= "table" then
  vim.snippet = {}
end

vim.snippet.expand = function(body)
  vim_snippet_expanded = body
end

package.loaded["luasnip"] = {
  lsp_expand = function(body)
    luasnip_expanded = body
  end,
}

package.loaded["snacks"] = {
  picker = {
    pick = function(spec)
      picker_spec = spec
    end,
  },
}

local ok, err = pcall(function()
  local ark = require("ark")

  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = false,
  })

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_snippets_prefer_luasnip.R")
  vim.bo[buf].filetype = "r"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkSnippets")

  if picker_spec == nil then
    error("expected ArkSnippets to open a Snacks picker", 0)
  end

  local fun = nil
  for _, item in ipairs(picker_spec.items or {}) do
    if item.label == "fun" then
      fun = item
      break
    end
  end

  if fun == nil then
    error("expected `fun` snippet item in Ark picker", 0)
  end

  picker_spec.confirm({
    close = function()
    end,
  }, fun)

  local expected = table.concat({
    "${1:name} <- function(${2:variables}) {",
    "\t${0}",
    "}",
  }, "\n")

  if luasnip_expanded ~= expected then
    error("expected Ark snippets to prefer LuaSnip expansion, got " .. vim.inspect({
      luasnip_expanded = luasnip_expanded,
      vim_snippet_expanded = vim_snippet_expanded,
    }), 0)
  end

  if vim_snippet_expanded ~= nil then
    error("expected Ark snippets to avoid vim.snippet when LuaSnip is available", 0)
  end
end)

package.loaded["luasnip"] = nil
if original_snippet_expand ~= nil then
  vim.snippet.expand = original_snippet_expand
end

if not ok then
  error(err, 0)
end
