local M = {}
local tmux = require("ark.tmux")

local function filetype_enabled(filetypes, filetype)
  return vim.tbl_contains(filetypes or {}, filetype)
end

local function root_dir(bufnr, markers)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return vim.loop.cwd()
  end

  local root = vim.fs.root(path, markers or {})
  return root or vim.fs.dirname(path) or vim.loop.cwd()
end

function M.config(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  return {
    name = opts.lsp.name,
    cmd = opts.lsp.cmd,
    cmd_env = tmux.bridge_env(opts.tmux),
    root_dir = root_dir(bufnr, opts.lsp.root_markers),
  }
end

function M.start(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
    return nil
  end

  return vim.lsp.start(M.config(opts, bufnr), { bufnr = bufnr })
end

function M.restart(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = opts.lsp.name })) do
    vim.lsp.stop_client(client.id)
  end

  return M.start(opts, bufnr)
end

return M
