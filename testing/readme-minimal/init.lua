local source = debug.getinfo(1, "S").source:sub(2)
local config_dir = vim.fs.dirname(vim.fs.normalize(source))
local testing_dir = vim.fs.dirname(config_dir)
local repo_root = vim.fs.dirname(testing_dir)

local function shared_lazy_dir(name)
  local path = vim.fs.normalize(vim.fn.expand("~/.local/share/nvim/lazy/" .. name))
  if vim.fn.isdirectory(path) == 1 then
    return path
  end
end

local function ensure_lazy()
  local local_lazy = vim.fs.normalize(vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
  if vim.fn.isdirectory(local_lazy) == 1 then
    return local_lazy
  end

  local shared = shared_lazy_dir("lazy.nvim")
  if shared then
    return shared
  end

  vim.fn.mkdir(vim.fs.dirname(local_lazy), "p")
  local output = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "--branch=stable",
    "https://github.com/folke/lazy.nvim.git",
    local_lazy,
  })
  if vim.v.shell_error ~= 0 then
    error("failed to bootstrap lazy.nvim for README test config: " .. output, 0)
  end

  return local_lazy
end

local function prepend_shared_site()
  local shared_site = vim.fs.normalize(vim.fn.expand("~/.local/share/nvim/site"))
  if vim.fn.isdirectory(shared_site) == 1 then
    vim.opt.runtimepath:prepend(shared_site)
  end
end

local function installed_plugin_dir(name)
  return shared_lazy_dir(name)
end

local function plugin_spec(repo, name)
  local dir = installed_plugin_dir(name)
  if dir then
    return {
      dir = dir,
      name = name,
    }
  end

  return {
    repo,
    name = name,
  }
end

vim.opt.runtimepath:prepend(ensure_lazy())
vim.opt.termguicolors = true

local filetypes = { "r", "rmd", "qmd", "quarto" }

vim.treesitter.language.register("markdown", "rmd")
vim.treesitter.language.register("markdown", "qmd")
vim.treesitter.language.register("markdown", "quarto")

local function parser_lang_for(bufnr)
  return vim.treesitter.language.get_lang(vim.bo[bufnr].filetype) or vim.bo[bufnr].filetype
end

local function ensure_treesitter(bufnr)
  prepend_shared_site()

  local lang = parser_lang_for(bufnr)
  if type(lang) ~= "string" or lang == "" then
    return false
  end

  pcall(vim.treesitter.start, bufnr, lang)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  return ok and parser ~= nil
end

local function notify_missing_send_parser(bufnr)
  if ensure_treesitter(bufnr) then
    return
  end

  local ft = vim.bo[bufnr].filetype
  local lang = parser_lang_for(bufnr)
  vim.schedule(function()
    vim.notify(
      string.format(
        "nvim-slimetree <CR> and <leader><CR> need a working Tree-sitter parser for '%s' (language '%s'). Install the relevant parser(s); at minimum, '.R' buffers need the 'r' parser.",
        ft,
        lang
      ),
      vim.log.levels.WARN
    )
  end)
end

local blink = plugin_spec("Saghen/blink.cmp", "blink.cmp")
blink.ft = filetypes
blink.config = function()
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
end

local autopairs = plugin_spec("windwp/nvim-autopairs", "nvim-autopairs")
autopairs.ft = filetypes
autopairs.config = function()
  require("nvim-autopairs").setup({
    map_cr = false,
  })
end

local slime = plugin_spec("jpalardy/vim-slime", "vim-slime")
slime.ft = filetypes
slime.init = function()
  vim.g.slime_no_mappings = 1
  vim.g.slime_dont_ask_default = 1
  vim.g.slime_bracketed_paste = 0
end

local slimetree = plugin_spec("conig/nvim-slimetree", "nvim-slimetree")
slimetree.ft = filetypes
slimetree.dependencies = { "vim-slime" }
slimetree.config = function()
  require("nvim-slimetree").setup({
    transport = {
      backend = "slime",
      async = true,
    },
    gootabs = {
      enabled = false,
    },
  })

  local st = require("nvim-slimetree")
  local map = vim.keymap.set

  map("n", "<CR>", function()
    st.slimetree.send_current()
  end, { desc = "Send current R form" })

  map("n", "<leader><CR>", function()
    st.slimetree.send_current({ hold_position = true })
  end, { desc = "Send current R form and hold cursor" })

  map("n", "<C-c><C-c>", function()
    st.slimetree.send_line()
  end, { desc = "Send current R line" })

  map("x", "<CR>", "<Plug>SlimeRegionSend", { remap = true, silent = true })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = filetypes,
    callback = function(args)
      ensure_treesitter(args.buf)
      notify_missing_send_parser(args.buf)
    end,
    desc = "Warn when Tree-sitter parsers needed by nvim-slimetree sends are missing",
  })
end

local ark = {
  dir = repo_root,
  name = "ark.nvim",
  ft = filetypes,
  dependencies = {
    "blink.cmp",
    "vim-slime",
    "nvim-slimetree",
  },
  build = "cargo build -p ark --bin ark-lsp",
  config = function()
    require("ark").setup({
      auto_start_pane = true,
      auto_start_lsp = true,
      async_startup = true,
      configure_slime = true,
    })
  end,
}

require("lazy").setup({
  blink,
  autopairs,
  slime,
  slimetree,
  ark,
}, {
  root = vim.fs.normalize(vim.fn.stdpath("data") .. "/lazy"),
  lockfile = vim.fs.joinpath(config_dir, "lazy-lock.json"),
  checker = { enabled = false },
  change_detection = {
    enabled = false,
    notify = false,
  },
  install = {
    missing = true,
  },
})

prepend_shared_site()
