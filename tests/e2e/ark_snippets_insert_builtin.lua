vim.opt.rtp:prepend(vim.fn.getcwd())

local picker_spec = nil
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
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_snippets_insert_builtin.R")
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

  local inserted = vim.wait(1000, function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    return lines[1] == "name <- function(variables) {"
      and lines[2] == "\t"
      and lines[3] == "}"
  end, 50, false)

  if not inserted then
    error("expected built-in snippet expansion to insert the function template, got " .. vim.inspect(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), 0)
  end
end)

if not ok then
  error(err, 0)
end
