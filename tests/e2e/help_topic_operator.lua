local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_help_topic_operator.R"

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

vim.fn.writefile({
  "?geom_point",
  "utils?help",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(0)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local function assert_help_topic_at(line, character, expected, label)
  local topic, err = require("ark.lsp").help_topic(require("ark.config").defaults(), 0, {
    line = line,
    character = character,
  })

  if topic ~= expected then
    ark_test.fail("unexpected help topic at " .. label .. ": " .. vim.inspect({
      topic = topic,
      expected = expected,
      error = err,
    }))
  end
end

assert_help_topic_at(0, 0, "geom_point", "unary operator")
assert_help_topic_at(0, 1, "geom_point", "unary topic start")
assert_help_topic_at(0, 6, "geom_point", "unary topic middle")
assert_help_topic_at(0, #"?geom_point", "geom_point", "unary topic end")

assert_help_topic_at(1, 0, "utils::help", "binary package")
assert_help_topic_at(1, 5, "utils::help", "binary operator")
assert_help_topic_at(1, 6, "utils::help", "binary topic start")
assert_help_topic_at(1, #"utils?help", "utils::help", "binary topic end")

vim.print({
  unary = "geom_point",
  binary = "utils::help",
})
