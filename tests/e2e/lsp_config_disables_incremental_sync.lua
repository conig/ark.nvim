vim.opt.rtp:prepend(vim.fn.getcwd())

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

local test_file = "/tmp/ark_lsp_config_disables_incremental_sync.R"
vim.fn.writefile({ "" }, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local config, err = require("ark").lsp_config(0)
if not config then
  error("expected ark lsp config, got " .. tostring(err), 0)
end

if type(config.flags) ~= "table" or config.flags.allow_incremental_sync ~= false then
  error("expected ark lsp config to disable incremental sync, got " .. vim.inspect(config.flags), 0)
end
