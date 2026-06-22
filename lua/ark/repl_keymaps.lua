local M = {}

local function keymap_prefix(opts)
  local raw = opts and opts.keymaps or nil
  if raw == true then
    raw = {}
  elseif type(raw) ~= "table" then
    raw = {}
  end

  return type(raw.prefix) == "string" and raw.prefix ~= "" and raw.prefix or "<leader>r"
end

local function open_view_under_cursor(bufnr)
  local ok, module = pcall(require, "ark")
  if not ok or type(module) ~= "table" then
    vim.notify("ark.nvim is not available", vim.log.levels.ERROR, { title = "ark.nvim" })
    return
  end

  if type(module.view_under_cursor) == "function" then
    module.view_under_cursor(bufnr)
  elseif type(module.view) == "function" then
    module.view(nil, bufnr)
  end
end

function M.attach_view_keymap(bufnr, opts)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local prefix = keymap_prefix(opts)
  local previous_prefix = vim.b[bufnr].ark_repl_view_keymap_prefix
  if previous_prefix == prefix then
    return
  end
  if type(previous_prefix) == "string" and previous_prefix ~= "" then
    pcall(vim.keymap.del, "n", previous_prefix .. "v", { buffer = bufnr })
    pcall(vim.keymap.del, "x", previous_prefix .. "v", { buffer = bufnr })
  end

  vim.keymap.set({ "n", "x" }, prefix .. "v", function()
    open_view_under_cursor(bufnr)
  end, { buffer = bufnr, desc = "Open ArkView under cursor or selection" })

  vim.b[bufnr].ark_repl_view_keymap_prefix = prefix
end

return M
