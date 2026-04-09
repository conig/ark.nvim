vim.opt.rtp:prepend(vim.fn.getcwd())

local notifications = {}
local picker_spec = nil
local picker_closed = 0
local expanded = nil

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

local original_snippet_expand = vim.snippet and vim.snippet.expand or nil
if type(vim.snippet) ~= "table" then
  vim.snippet = {}
end

vim.snippet.expand = function(body)
  expanded = body
end

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
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_snippets_command.R")
  vim.bo[buf].filetype = "r"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkSnippets")

  if picker_spec == nil then
    error("expected ArkSnippets to open a Snacks picker", 0)
  end

  if picker_spec.title ~= "Ark Snippets" then
    error("unexpected Ark snippets picker title: " .. vim.inspect(picker_spec.title), 0)
  end

  if picker_spec.preview ~= "preview" then
    error("expected Ark snippets picker to use preview panes", 0)
  end

  if type(picker_spec.confirm) ~= "function" then
    error("expected Ark snippets picker to define a confirm callback", 0)
  end

  if type(picker_spec.layout) ~= "table" then
    error("expected Ark snippets picker to define a Snacks layout", 0)
  end

  local items = picker_spec.items or {}
  if #items ~= 18 then
    error("expected eighteen Ark snippets, got " .. tostring(#items), 0)
  end

  local by_label = {}
  for _, item in ipairs(items) do
    by_label[item.label] = item
    if type(item.preview) ~= "table" or type(item.preview.text) ~= "string" or item.preview.text == "" then
      error("expected each Ark snippet item to provide preview text: " .. vim.inspect(item), 0)
    end
  end

  local fun = by_label.fun
  if fun == nil then
    error("expected `fun` snippet item in Ark picker", 0)
  end

  for _, label in ipairs({ "lib", "req", "src", "ret", "lapply", "sapply", "vapply", "switch" }) do
    if by_label[label] == nil then
      error("expected `" .. label .. "` snippet item in Ark picker", 0)
    end
  end

  if not fun.preview.text:find("function%(", 1) then
    error("expected `fun` preview to show the function template, got " .. vim.inspect(fun.preview), 0)
  end

  picker_spec.confirm({
    close = function()
      picker_closed = picker_closed + 1
    end,
  }, fun)

  if picker_closed ~= 1 then
    error("expected Ark snippets picker to close before inserting", 0)
  end

  local expected = table.concat({
    "${1:name} <- function(${2:variables}) {",
    "\t${0}",
    "}",
  }, "\n")
  if expanded ~= expected then
    error("expected Ark snippets picker to expand the selected snippet, got " .. vim.inspect(expanded), 0)
  end

  if #notifications ~= 0 then
    error("expected ArkSnippets happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end
end)

vim.notify = original_notify
if original_snippet_expand ~= nil then
  vim.snippet.expand = original_snippet_expand
end

if not ok then
  error(err, 0)
end
