local ark_test = require("ark_test")

require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = false,
})

local test_file = ark_test.run_tmpdir() .. "/unterminated_string_diagnostic.R"
local initial_lines = {
  "function(x) {",
  '  "',
  "}",
}
vim.fn.writefile(initial_lines, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

local lsp_config = require("ark").lsp_config(0)
ark_test.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

require("ark").start_lsp(0)

local function replace_lines(lines)
  vim.diagnostic.reset(nil, 0)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

local function assert_diagnostic(label, lines, expected)
  replace_lines(lines)

  ark_test.wait_for(label, 15000, function()
    local diagnostics = vim.diagnostic.get(0)
    if #diagnostics ~= 1 then
      return false
    end

    local diagnostic = diagnostics[1]
    return diagnostic.message == expected.message
      and diagnostic.lnum == expected.lnum
      and diagnostic.col == expected.col
      and diagnostic.end_lnum == expected.end_lnum
      and diagnostic.end_col == expected.end_col
  end)

  local diagnostics = vim.diagnostic.get(0)
  if #diagnostics ~= 1 then
    ark_test.fail(label .. ": expected one diagnostic: " .. vim.inspect(diagnostics))
  end
end

assert_diagnostic("unterminated string in function", initial_lines, {
  message = "Unterminated string literal",
  lnum = 1,
  col = 2,
  end_lnum = 1,
  end_col = 3,
})

assert_diagnostic("valid multiline string", {
  'list("foo',
  'bar" x)',
}, {
  message = "Syntax error",
  lnum = 0,
  col = 5,
  end_lnum = 1,
  end_col = 4,
})

assert_diagnostic("valid escaped-newline string", {
  'list("foo\\',
  'bar" x)',
}, {
  message = "Syntax error",
  lnum = 0,
  col = 5,
  end_lnum = 1,
  end_col = 4,
})

assert_diagnostic("valid single-quoted raw string", {
  "list(r'(foo",
  "bar)' x)",
}, {
  message = "Syntax error",
  lnum = 0,
  col = 5,
  end_lnum = 1,
  end_col = 5,
})

assert_diagnostic("unterminated string at EOF", {
  'x <- "',
}, {
  message = "Unterminated string literal",
  lnum = 0,
  col = 5,
  end_lnum = 0,
  end_col = 6,
})

vim.print("unterminated string diagnostics: ok")
