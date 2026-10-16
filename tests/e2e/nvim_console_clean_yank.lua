vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.maplocalleader = ","

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "nvim_console_clean_yank")
local clipboard = { lines = {}, regtype = "v" }
vim.g.clipboard = {
  name = "ark-clean-yank-test",
  copy = {
    ["+"] = function(lines, regtype)
      clipboard = { lines = lines, regtype = regtype }
    end,
  },
  paste = {
    ["+"] = function()
      return { clipboard.lines, clipboard.regtype }
    end,
  },
}

local run_tmpdir = vim.fn.tempname()
vim.fn.mkdir(run_tmpdir, "p")
local launcher = run_tmpdir .. "/fake-r"
vim.fn.writefile({
  "#!/usr/bin/env bash",
  "printf '%s\\n' '  @Manual{,' '    title = {corx},' '  }' '#> literal output' 'αβ value'",
  "printf '> '",
  "while IFS= read -r line; do",
  "  printf 'saw: %s\\n> ' \"$line\"",
  "done",
}, launcher)
vim.fn.setfperm(launcher, "rwxr-xr-x")
require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  console = { history = { enabled = false } },
  terminal = {
    launcher = launcher,
    startup_status_dir = run_tmpdir .. "/status",
    session_pkg_path = run_tmpdir .. "/arkbridge",
  },
})
local console = require("ark.console")
local bufnr = assert(require("ark").console())
local function find_line(text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line == text then
      return row
    end
  end
end
ark_test.wait_for("BibTeX output", 5000, function()
  return find_line("#> αβ value") and console.status(bufnr).prompt_state == "top-level"
end)

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end
local function select_region(first_row, first_col, last_row, last_col, mode)
  feed("<Esc>")
  vim.api.nvim_win_set_cursor(0, { first_row, first_col })
  feed(mode or "v")
  vim.api.nvim_win_set_cursor(0, { last_row, last_col })
end
local function expect_clipboard(text, regtype)
  assert(
    vim.fn.getreg("+") == text,
    vim.inspect({
      expected = text,
      actual = vim.fn.getreg("+"),
      regtype = vim.fn.getregtype("+"),
      clipboard = clipboard,
    })
  )
  assert(vim.fn.getregtype("+") == regtype, vim.inspect(vim.fn.getregtype("+")))
end

local bib_row = assert(find_line("#>   @Manual{,"))
local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
-- The actual user workflow: select printed BibTeX and clean-yank to clipboard.
select_region(bib_row, 0, bib_row + 2, 0, "V")
feed(",y")
expect_clipboard("  @Manual{,\n    title = {corx},\n  }\n", "V")
assert(vim.fn.mode() == "n", "clean yank should leave Visual mode")
assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)), "yank modified transcript")

-- Ordinary y retains transcript comments; clean yank removes only one synthetic prefix.
select_region(bib_row, 0, bib_row + 2, 0, "V")
feed("y")
expect_clipboard("#>   @Manual{,\n#>     title = {corx},\n#>   }\n", "V")
local literal_row = assert(find_line("#> #> literal output"))
select_region(literal_row, 0, literal_row, 0, "V")
feed(",y")
expect_clipboard("#> literal output\n", "V")

-- Partial and backwards selections must use source columns, not regex on copied text.
select_region(literal_row, 3, literal_row, 5)
feed(",y")
expect_clipboard("#> ", "v")
select_region(literal_row, 1, literal_row, 5)
feed(",y")
expect_clipboard("#> ", "v")
select_region(literal_row, 5, literal_row, 0)
feed(",y")
expect_clipboard("#> ", "v")
vim.o.selection = "exclusive"
select_region(literal_row, 0, literal_row, 6)
feed(",y")
expect_clipboard("#> ", "v")
vim.o.selection = "inclusive"
select_region(bib_row, 5, bib_row + 1, 11)
feed(",y")
expect_clipboard("@Manual{,\n    title", "v")

select_region(bib_row, 0, bib_row + 1, 4, "<C-v>")
feed(",y")
expect_clipboard("  \n  ", "\22" .. "2")
select_region(bib_row, 3, bib_row + 1, 4, "<C-v>")
feed(",y")
expect_clipboard("  \n  ", "\22" .. "2")
local unicode_row = assert(find_line("#> αβ value"))
select_region(unicode_row, 0, unicode_row, 5)
feed(",y")
expect_clipboard("αβ", "v")

-- Submitted comments and editable draft text are not Ark-generated output.
assert(console.send_text(bufnr, "#> user comment"))
ark_test.wait_for("submitted comment", 5000, function()
  return find_line("#> saw: #> user comment") and console.status(bufnr).prompt_state == "top-level"
end)
local comment_row = assert(find_line("#> user comment"))
select_region(comment_row, 0, comment_row + 1, 0, "V")
feed(",y")
expect_clipboard("#> user comment\nsaw: #> user comment\n", "V")
-- Edit-protection restoration must retain the metadata used to recognize code.
vim.api.nvim_buf_set_lines(bufnr, comment_row - 1, comment_row, false, { "#> rejected edit" })
ark_test.wait_for("protected comment restored", 5000, function()
  return find_line("#> user comment") == comment_row
end)
select_region(comment_row, 0, comment_row, 0, "V")
feed(",y")
expect_clipboard("#> user comment\n", "V")
local input_start = console.status(bufnr).input_start
vim.api.nvim_buf_set_lines(bufnr, input_start, -1, false, { "#> draft", "", "\tindented" })
select_region(input_start + 1, 0, input_start + 3, 0, "V")
feed(",y")
expect_clipboard("#> draft\n\n\tindented\n", "V")

-- Extraction is side-effect free; callers can choose the original transcript or a named register.
select_region(bib_row, 0, bib_row + 2, 0, "V")
local selection = assert(console.get_selection({ format = "transcript" }))
assert(selection.lines[1] == "#>   @Manual{," and selection.regtype == "V")
local invalid, format_err = console.get_selection({ format = "invalid" })
assert(not invalid and format_err:find("format"), "invalid format should be rejected")
expect_clipboard("#> draft\n\n\tindented\n", "V")
assert(console.yank({ register = "a" }))
assert(vim.fn.getreg("a") == "  @Manual{,\n    title = {corx},\n  }\n")
expect_clipboard("#> draft\n\n\tindented\n", "V")
local missing, err = console.get_selection()
assert(not missing and err:find("Visual"), "selection API should reject non-Visual mode")

assert(console.stop(bufnr))
stop_watchdog()
vim.print({ nvim_console_clean_yank = "ok" })
