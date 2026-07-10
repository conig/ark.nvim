vim.opt.rtp:prepend(vim.fn.getcwd())

local help_render = require("ark.help_render")

local rendered = help_render.render({
  "stats::lm",
  "",
  "Description:",
  "  Fit linear models.",
  "",
  "Usage:",
  "",
  "  lm(formula, data)",
  "",
  "Arguments:",
  "  formula: a model formula",
})

assert(vim.tbl_contains(rendered.lines, "Contents:"), "help renderer did not create a table of contents")
assert(vim.tbl_contains(rendered.lines, "```r"), "help renderer did not fence the Usage section")
assert(#rendered.code_blocks == 1, "help renderer did not expose its code block layout")
assert(#rendered.toc_entries == 3, "help renderer did not expose section navigation entries")
assert(
  help_render.expression("stats::lm") == 'utils::help("lm", package = "stats", help_type = "text")',
  "qualified help expression changed during renderer extraction"
)
