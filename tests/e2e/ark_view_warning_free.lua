vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

if vim.fn.executable("Rscript") ~= 1 then
  ark_test.skip("Rscript is required for ArkView warning regression coverage")
end

local script = table.concat({
  "options(warn = 1)",
  "source('packages/arkbridge/R/utils.R')",
  "source('packages/arkbridge/R/view.R')",
  "warnings <- character()",
  "record <- function(expr) {",
  "  withCallingHandlers(",
  "    force(expr),",
  "    warning = function(w) {",
  "      warnings <<- c(warnings, conditionMessage(w))",
  "      invokeRestart('muffleWarning')",
  "    }",
  "  )",
  "}",
  "record(.ark_view_generate_id())",
  "df <- data.frame(name = c('Mazda RX4', 'Honda Civic'), stringsAsFactors = FALSE)",
  "record(.ark_view_apply_filters(df, list('1' = 'mazda')))",
  "record(.ark_view_apply_filters(df, list('1' = 'HONDA')))",
  "if (length(warnings)) {",
  "  stop(paste(warnings, collapse = '\\n'), call. = FALSE)",
  "}",
}, "\n")

local output = vim.fn.system({ "Rscript", "--vanilla", "-e", script })
if vim.v.shell_error ~= 0 then
  ark_test.fail("ArkView warning-free regression failed:\n" .. output)
end
