local ark_test = require("ark_test")

local function diagnostic_messages()
  local messages = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    messages[#messages + 1] = diagnostic.message
  end
  table.sort(messages)
  return messages
end

local function contains(messages, needle)
  for _, message in ipairs(messages) do
    if message == needle then
      return true
    end
  end
  return false
end

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_edit_syntax_diagnostics_after_live_clear.R"
vim.fn.writefile({
  "x <- file.path('a', 'b')",
  "dir.create('outputs')",
  "hits <- grep('a', c('a', 'b'), value = TRUE)",
  "opts <- list(a = 1)",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(0)

ark_test.wait_for("initial static lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

vim.wait(500, function()
  return false
end, 100, false)

local initial_messages = diagnostic_messages()

if #initial_messages > 0 then
  error(vim.inspect({
    initial_diagnostics = initial_messages,
    stage = "before pane startup",
    status = require("ark").status({ include_lsp = true }),
  }), 0)
end

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  error(pane_err or "failed to start managed pane", 0)
end

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

ark_test.wait_for("live diagnostics remain clear after hydration", 10000, function()
  return #diagnostic_messages() == 0
end)

vim.cmd([[execute "normal! Go"]])
vim.cmd([[execute "normal! iggplot(mtcars, aes(wt, mpg)\<Esc>"]])

local syntax_message = "Unmatched opening delimiter. Missing a closing ')'."
local diagnostics_settled = vim.wait(10000, function()
  return contains(diagnostic_messages(), syntax_message)
end, 100, false)

local final_messages = diagnostic_messages()

if not diagnostics_settled then
  error(vim.inspect({
    initial_diagnostics = initial_messages,
    final_diagnostics = final_messages,
    status = require("ark").status(),
  }), 0)
end

if not contains(final_messages, syntax_message) then
  error(vim.inspect({
    initial_diagnostics = initial_messages,
    final_diagnostics = final_messages,
    status = require("ark").status(),
  }), 0)
end

vim.print({
  initial_diagnostics = initial_messages,
  final_diagnostics = final_messages,
  status = require("ark").status(),
})
