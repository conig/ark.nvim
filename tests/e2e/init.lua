local repo_root = vim.fs.normalize(vim.env.ARK_REPO_ROOT or vim.fn.getcwd())
vim.opt.runtimepath:prepend(repo_root)

local blink_root = vim.fs.normalize(vim.fn.stdpath("data") .. "/lazy/blink.cmp")
if vim.fn.isdirectory(blink_root) ~= 1 then
  error("blink.cmp is required for Blink-backed E2Es: missing " .. blink_root, 0)
end

vim.opt.runtimepath:prepend(blink_root)
vim.opt.termguicolors = true

require("blink.cmp").setup({
  fuzzy = {
    implementation = "lua",
  },
  completion = {
    documentation = {
      auto_show = true,
    },
  },
  sources = {
    default = { "lsp", "path", "buffer" },
  },
})

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = true,
  configure_slime = true,
})
