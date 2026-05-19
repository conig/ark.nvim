local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_rmd_frontmatter_help_topic.Rmd"
local output_line = "output: revise::revise_letter_pdf"

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

vim.fn.writefile({
  "---",
  'title: "Ark R Markdown help topic"',
  output_line,
  "---",
  "",
  "Body",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype rmd")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(0)

ark_test.wait_for("ark lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local function assert_help_topic_at(character, label)
  local topic, err = require("ark.lsp").help_topic(require("ark.config").defaults(), 0, {
    line = 2,
    character = character,
  })

  if topic ~= "revise::revise_letter_pdf" then
    ark_test.fail("unexpected frontmatter output help topic at " .. label .. ": " .. vim.inspect({
      topic = topic,
      error = err,
    }))
  end
end

-- Regression: `leader r?` asks Ark for the symbol under the cursor before
-- fetching help text. Rmd frontmatter is masked out of the R parse view, so the
-- help-topic request must recover output renderers from the original YAML text.
assert_help_topic_at(10, "package")
assert_help_topic_at(17, "renderer")
assert_help_topic_at(#output_line, "end")

vim.print({
  topic = "revise::revise_letter_pdf",
})
