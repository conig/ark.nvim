vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(60000, "targets_view_direct")

if vim.fn.executable("R") ~= 1 or vim.fn.executable("Rscript") ~= 1 then
  ark_test.fail("R and Rscript are required for direct target ArkView")
end

vim.fn.system({ "Rscript", "-e", "if (!requireNamespace('targets', quietly = TRUE)) quit(status = 42)" })
if vim.v.shell_error ~= 0 then
  ark_test.fail("targets package is required for direct target ArkView")
end

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/targets-view-direct")
vim.fn.mkdir(root, "p")
vim.fn.writefile({
  "library(targets)",
  "tar_option_set(packages = character())",
  "list(",
  "  tar_target(clean_data, data.frame(id = 1:3, value = c('a', 'b', 'c'), score = c(1.5, 2.5, 3.5)))",
  ")",
}, root .. "/_targets.R")

local build = vim.fn.system({
  "Rscript",
  "-e",
  "setwd(" .. vim.fn.string(root) .. "); targets::tar_make(callr_function = NULL)",
})
if vim.v.shell_error ~= 0 then
  ark_test.fail("failed to build direct target ArkView fixture: " .. tostring(build))
end

local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  configure_slime = false,
  view = {
    display = "tab",
  },
})

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, root .. "/_targets.R")
vim.bo[source_buf].filetype = "r"

local started_pane = false
local session = require("ark.session")
session.start = function()
  started_pane = true
  return nil, "direct target ArkView should not start a managed pane"
end

local opened, err = ark.targets_view("clean_data", source_buf)
if not opened then
  ark_test.fail("failed to open direct target ArkView: " .. tostring(err))
end
if started_pane then
  ark_test.fail("direct target ArkView started the managed pane")
end

if tonumber(opened.total_rows or 0) ~= 3 or tonumber(opened.total_columns or 0) ~= 3 then
  ark_test.fail("unexpected direct target ArkView dimensions: " .. vim.inspect(opened))
end

local columns = {}
for _, column in ipairs(opened.schema or {}) do
  columns[column.name] = true
end
for _, name in ipairs({ "id", "value", "score" }) do
  if not columns[name] then
    ark_test.fail("direct target ArkView missing column " .. name .. ": " .. vim.inspect(opened.schema))
  end
end

ark.view_close()

local expression_opened, expression_err = ark.view("targets::tar_read(name = 'clean_data')", source_buf)
if not expression_opened then
  ark_test.fail("failed to open target ArkView from tar_read expression: " .. tostring(expression_err))
end
if started_pane then
  ark_test.fail("tar_read expression target ArkView started the managed pane")
end
if tonumber(expression_opened.total_rows or 0) ~= 3 or tonumber(expression_opened.total_columns or 0) ~= 3 then
  ark_test.fail("unexpected tar_read expression ArkView dimensions: " .. vim.inspect(expression_opened))
end

ark.view_close()

vim.print({
  targets_view_direct = "ok",
})

stop_watchdog()
