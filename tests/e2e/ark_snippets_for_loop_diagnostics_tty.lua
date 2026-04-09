local repo_root = vim.fn.getcwd()

vim.opt.rtp:prepend(repo_root)
vim.opt.rtp:prepend(vim.fs.normalize(vim.fn.expand("~/.local/share/nvim/lazy/LuaSnip")))

local ark_test = dofile(vim.fs.normalize(repo_root .. "/tests/e2e/ark_test.lua"))

local picker_spec = nil
package.loaded["snacks"] = {
  picker = {
    pick = function(spec)
      picker_spec = spec
    end,
  },
}

local function diagnostic_messages(bufnr)
  local messages = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(bufnr)) do
    messages[#messages + 1] = diagnostic.message
  end
  return messages
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

local test_file = "/tmp/ark_snippets_for_loop_diagnostics_tty.R"
vim.fn.writefile({
  "cats <- 1:3",
  "",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")
vim.api.nvim_win_set_cursor(0, { 2, 0 })

require("ark").start_lsp(0)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true
end)

dofile(vim.fs.normalize(repo_root .. "/plugin/ark.lua"))
vim.cmd("ArkSnippets")

if picker_spec == nil then
  error("expected ArkSnippets to open a Snacks picker", 0)
end

local target = nil
for _, item in ipairs(picker_spec.items or {}) do
  if item.label == "for" then
    target = item
    break
  end
end

if target == nil then
  error("expected `for` snippet item in Ark picker", 0)
end

picker_spec.confirm({
  close = function()
  end,
}, target)

vim.defer_fn(function()
  vim.api.nvim_input("dog")
end, 300)

vim.defer_fn(function()
  require("luasnip").jump(1)
  vim.api.nvim_input("cats")
end, 900)

vim.defer_fn(function()
  require("luasnip").jump(1)
end, 1500)

vim.defer_fn(function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local diagnostics = diagnostic_messages(0)

  if lines[2] ~= "for (dog in cats) {" or #diagnostics ~= 0 then
    error("expected valid filled `for` snippet to stay lint-clean, got " .. vim.inspect({
      lines = lines,
      diagnostics = diagnostics,
    }), 0)
  end

  vim.cmd("qa!")
end, 3000)
