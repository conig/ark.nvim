local repo_root = vim.fs.normalize(vim.env.ARK_REPO_ROOT or vim.fn.getcwd())
vim.g.mapleader = " "
vim.opt.runtimepath:prepend(repo_root)

local function prepend_lazy_plugin(name, required)
  local root = vim.fs.normalize(vim.fn.stdpath("data") .. "/lazy/" .. name)
  if vim.fn.isdirectory(root) == 1 then
    vim.opt.runtimepath:prepend(root)
    return
  end

  if required then
    error(name .. " is required for Blink-backed E2Es: missing " .. root, 0)
  end
end

prepend_lazy_plugin("snacks.nvim", false)
prepend_lazy_plugin("blink.lib", false)
prepend_lazy_plugin("blink.cmp", true)
vim.opt.termguicolors = true

vim.keymap.set("n", "<leader>y", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if lines[1] == "---" then
    for index = 2, #lines do
      if lines[index] == "---" then
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! zz")
        return
      end
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "---", "", "---" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  vim.cmd("normal! zz")
  vim.cmd("startinsert")
end, { desc = "Insert YAML frontmatter", silent = true })

require("blink.cmp").setup({
  fuzzy = {
    implementation = "lua",
  },
  keymap = {
    ["<CR>"] = { "accept", "fallback" },
  },
  completion = {
    documentation = {
      auto_show = true,
    },
    trigger = {
      show_on_blocked_trigger_characters = { "\n", "\t" },
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
  keymaps = true,
})
