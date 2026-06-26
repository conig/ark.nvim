local M = {}

local function keymap_prefixes(opts)
  local raw = opts and opts.keymaps or nil
  if raw == true then
    raw = {}
  elseif type(raw) ~= "table" then
    raw = {}
  end

  local prefix = type(raw.prefix) == "string" and raw.prefix ~= "" and raw.prefix or "<leader>r"
  local target_prefix = type(raw.target_prefix) == "string" and raw.target_prefix ~= "" and raw.target_prefix
    or "<leader>t"
  return prefix, target_prefix
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

local function open_target_view(bufnr)
  local ok, module = pcall(require, "ark")
  if not ok or type(module) ~= "table" then
    vim.notify("ark.nvim is not available", vim.log.levels.ERROR, { title = "ark.nvim" })
    return
  end

  if type(module.targets_view_pick) == "function" then
    module.targets_view_pick(bufnr)
  else
    vim.notify("ark.nvim target ArkView API is not available", vim.log.levels.ERROR, { title = "ark.nvim" })
  end
end

local function terminal_buffer(bufnr)
  return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal"
end

function M.attach_view_keymap(bufnr, opts)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local prefix, target_prefix = keymap_prefixes(opts)
  local previous_prefix = vim.b[bufnr].ark_repl_view_keymap_prefix
  local previous_target_prefix = vim.b[bufnr].ark_repl_view_keymap_target_prefix
  if previous_prefix == prefix and previous_target_prefix == target_prefix then
    return
  end
  if type(previous_prefix) == "string" and previous_prefix ~= "" then
    pcall(vim.keymap.del, "n", previous_prefix .. "v", { buffer = bufnr })
    pcall(vim.keymap.del, "x", previous_prefix .. "v", { buffer = bufnr })
    pcall(vim.keymap.del, "t", previous_prefix .. "v", { buffer = bufnr })
    pcall(vim.keymap.del, "n", previous_prefix .. "V", { buffer = bufnr })
    pcall(vim.keymap.del, "x", previous_prefix .. "V", { buffer = bufnr })
    pcall(vim.keymap.del, "t", previous_prefix .. "V", { buffer = bufnr })
  end
  if type(previous_target_prefix) == "string" and previous_target_prefix ~= "" then
    pcall(vim.keymap.del, "n", previous_target_prefix .. "v", { buffer = bufnr })
    pcall(vim.keymap.del, "t", previous_target_prefix .. "v", { buffer = bufnr })
  end

  vim.keymap.set({ "n", "x" }, prefix .. "v", function()
    open_view_under_cursor(bufnr)
  end, { buffer = bufnr, desc = "Open ArkView under cursor or selection" })

  vim.keymap.set({ "n", "x" }, prefix .. "V", function()
    open_view_under_cursor(bufnr)
  end, { buffer = bufnr, desc = "Open ArkView under cursor or selection" })

  vim.keymap.set("n", target_prefix .. "v", function()
    open_target_view(bufnr)
  end, { buffer = bufnr, desc = "Open ArkView for target" })

  if terminal_buffer(bufnr) then
    vim.keymap.set("t", prefix .. "v", function()
      open_view_under_cursor(bufnr)
    end, { buffer = bufnr, desc = "Open ArkView under cursor or selection" })

    vim.keymap.set("t", prefix .. "V", function()
      open_view_under_cursor(bufnr)
    end, { buffer = bufnr, desc = "Open ArkView under cursor or selection" })

    vim.keymap.set("t", target_prefix .. "v", function()
      open_target_view(bufnr)
    end, { buffer = bufnr, desc = "Open ArkView for target" })
  end

  vim.b[bufnr].ark_repl_view_keymap_prefix = prefix
  vim.b[bufnr].ark_repl_view_keymap_target_prefix = target_prefix
end

return M
