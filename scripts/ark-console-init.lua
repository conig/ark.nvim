vim.g.ark_console_standalone = true
vim.g.ark_console_terminal_ui = true
vim.g.mapleader = " "
vim.g.maplocalleader = " "

local function repo_root()
  local source = debug.getinfo(1, "S").source
  if vim.startswith(source, "@") then
    source = source:sub(2)
  end
  return vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
end

local root = vim.fs.normalize(vim.env.ARK_REPO_ROOT or repo_root())
vim.opt.runtimepath:prepend(root)

local function prepend_lazy_plugin(name)
  local path = vim.fs.normalize((vim.fn.stdpath("data") or "") .. "/lazy/" .. name)
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
  end
end

local function ark_repl_config_dir()
  local override = vim.env.ARK_NVIM_REPL_CONFIG_DIR or vim.env.ARK_NVIM_CONSOLE_CONFIG_DIR
  if type(override) == "string" and override ~= "" then
    return vim.fs.normalize(vim.fn.expand(override))
  end

  local config_home = vim.env.XDG_CONFIG_HOME
  if type(config_home) ~= "string" or config_home == "" then
    local home = vim.env.HOME
    if type(home) ~= "string" or home == "" then
      return nil
    end
    config_home = home .. "/.config"
  end

  return vim.fs.normalize(config_home .. "/ark.nvim/ark-repl")
end

local function source_optional_lua(path)
  if type(path) == "string" and vim.fn.filereadable(path) == 1 then
    dofile(path)
  end
end

prepend_lazy_plugin("blink.lib")
prepend_lazy_plugin("blink.cmp")
prepend_lazy_plugin("nvim-autopairs")
prepend_lazy_plugin("snacks.nvim")

local repl_config_dir = ark_repl_config_dir()
vim.g.ark_repl_config_dir = repl_config_dir
if type(repl_config_dir) == "string" and vim.fn.isdirectory(repl_config_dir) == 1 then
  vim.opt.runtimepath:prepend(repl_config_dir)
end

vim.opt.termguicolors = true
vim.opt.shortmess:append("I")
vim.opt.showtabline = 0
vim.opt.laststatus = 0
vim.opt.statusline = " "
vim.opt.ruler = false
vim.opt.showcmd = false
vim.opt.number = false
vim.opt.relativenumber = false
vim.opt.signcolumn = "no"
vim.opt.foldcolumn = "0"
vim.opt.cmdheight = 0
vim.opt.wrap = true
vim.opt.list = false
vim.opt.swapfile = false
vim.opt.fillchars = {
  eob = " ",
  lastline = " ",
}

local ok_autopairs, autopairs = pcall(require, "nvim-autopairs")
if ok_autopairs and type(autopairs.setup) == "function" then
  pcall(autopairs.setup, {})
end

local ok_blink, blink = pcall(require, "blink.cmp")
if ok_blink then
  blink.setup({
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
end

if type(repl_config_dir) == "string" then
  source_optional_lua(repl_config_dir .. "/init.lua")
end

vim.cmd("runtime plugin/ark.lua")
