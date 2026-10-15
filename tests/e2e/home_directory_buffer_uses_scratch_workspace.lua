local ark_test = require("ark_test")

local home_dir = vim.fs.normalize(vim.env.HOME or "")
local cwd = vim.fs.normalize(vim.loop.cwd())
if home_dir == "" or cwd ~= home_dir then
  ark_test.fail(string.format("expected test cwd to equal HOME, got cwd=%s home=%s", cwd, home_dir))
end

local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype == "" then
  vim.cmd("setfiletype r")
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local lsp_config = require("ark").lsp_config(bufnr)
local root_dir = lsp_config and vim.fs.normalize(lsp_config.root_dir or "") or ""
local scratch_root = vim.fs.normalize((vim.fn.stdpath("state") or "/tmp") .. "/ark-unnamed-workspace")

-- Reproduce the real startup shape from `~`: a direct home-directory R file
-- should not widen the detached workspace to the whole home directory.
if root_dir ~= scratch_root then
  ark_test.fail(vim.inspect({
    error = "home-directory R buffer should use scratch workspace root",
    root_dir = root_dir,
    scratch_root = scratch_root,
    home_dir = home_dir,
    bufname = vim.api.nvim_buf_get_name(bufnr),
  }))
end

-- Giving project consoles a real workspace must not make an ad hoc console
-- launched from HOME scan the user's entire home directory.
local console_bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(console_bufnr, "ark-console://home-scratch-test")
vim.b[console_bufnr].ark_console = true
local console_config = require("ark").lsp_config(console_bufnr)
assert(
  vim.fs.normalize(console_config.root_dir) == scratch_root,
  "home-directory console should retain scratch workspace isolation"
)

vim.print({
  root_dir = root_dir,
  scratch_root = scratch_root,
  bufname = vim.api.nvim_buf_get_name(bufnr),
})
