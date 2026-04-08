local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local ok_blink, blink = pcall(require, "blink.cmp")
if not ok_blink then
  ark_test.fail("blink.cmp is required for this test")
end

require("blink.cmp.config").completion.accept.dot_repeat = false

local list = require("blink.cmp.completion.list")

local test_file = "/tmp/ark_string_accept_completion.R"
local lines = {
  'iris$Species == ""',
  'cor(mtcars, method = "")',
  'mtcars[, c("")]',
  'library("u")',
}

ark_test.setup_managed_buffer(test_file, lines)

local function item_index(label)
  for index, item in ipairs(list.items) do
    if item.label == label then
      return index
    end
  end
end

local function completion_cursor(line)
  if line == 4 then
    local start_index = assert(lines[line]:find('"u"', 1, true))
    return start_index + 1
  end

  local start_index = assert(lines[line]:find('""', 1, true))
  return start_index
end

local function wait_for_item(label)
  ark_test.wait_for("blink completion item " .. label, 4000, function()
    if not blink.is_visible() then
      return false
    end

    return item_index(label) ~= nil
  end)
end

local function accept_string_completion(line, label, expected_line, expected_under_cursor, opts)
  opts = opts or {}
  vim.api.nvim_win_set_cursor(0, { line, completion_cursor(line) })
  vim.cmd("startinsert")
  require("blink.cmp.completion.trigger").show({
    trigger_kind = "trigger_character",
    trigger_character = '"',
  })
  wait_for_item(label)

  if opts.expect_no_snippets then
    ark_test.assert_no_snippet_items(list.items, label)
  end

  local index = item_index(label)
  if not index then
    ark_test.fail("missing completion item: " .. label)
  end

  local item = list.items[index]
  if ((item.command or {}).command) ~= "ark.completeStringDelimiter" then
    ark_test.fail("string completion missing delimiter command: " .. vim.inspect(item))
  end

  list.accept({ index = index })

  local accepted = vim.wait(4000, function()
    return vim.api.nvim_get_current_line() == expected_line
  end, 100, false)
  if not accepted then
    ark_test.fail(
      string.format(
        "accepted %s produced unexpected line %q at %s",
        label,
        vim.api.nvim_get_current_line(),
        vim.inspect(vim.api.nvim_win_get_cursor(0))
      )
    )
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = vim.api.nvim_get_current_line()
  local char_under_cursor = current_line:sub(cursor[2] + 1, cursor[2] + 1)
  local char_before_cursor = cursor[2] > 0 and current_line:sub(cursor[2], cursor[2]) or ""

  if char_under_cursor ~= expected_under_cursor then
    ark_test.fail(
      string.format(
        "accepted %s left cursor on unexpected character %q in %q",
        label,
        char_under_cursor,
        current_line
      )
    )
  end

  if char_before_cursor ~= '"' then
    ark_test.fail(
      string.format(
        "accepted %s did not leave cursor after closing quote in %q",
        label,
        current_line
      )
    )
  end

  vim.cmd("stopinsert")
end

accept_string_completion(1, "setosa", 'iris$Species == "setosa"', "", {
  expect_no_snippets = true,
})
accept_string_completion(2, "pearson", 'cor(mtcars, method = "pearson")', ")", {
  expect_no_snippets = true,
})
accept_string_completion(3, "mpg", 'mtcars[, c("mpg")]', ")", {
  expect_no_snippets = true,
})
accept_string_completion(4, "utils", 'library("utils")', ")")

vim.print({
  comparison = true,
  argument = true,
  subset = true,
  library = true,
})
