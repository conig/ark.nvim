local ark_test = require("ark_test")

local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype == "" then
  vim.cmd("setfiletype r")
end

require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = false,
  configure_slime = true,
})

local pane_ready = vim.wait(20000, function()
  return require("ark").status().bridge_ready == true
end, 100, false)

if not pane_ready then
  ark_test.fail(vim.inspect({
    filetype = vim.bo[bufnr].filetype,
    bufnr = bufnr,
    bufname = vim.api.nvim_buf_get_name(bufnr),
    status = require("ark").status({ include_lsp = true }),
  }))
end

ark_test.wait_for("managed repl readiness from existing R buffer", 20000, function()
  return require("ark").status().repl_ready == true
end)

ark_test.wait_for("ark lsp startup from existing R buffer", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

vim.print(require("ark").status({ include_lsp = true }))
