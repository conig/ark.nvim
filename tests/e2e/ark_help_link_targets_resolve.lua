vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

if vim.fn.executable("Rscript") ~= 1 then
  ark_test.fail("Rscript is required for ArkHelp link target regression coverage")
end

local script = [[
source("packages/arkbridge/R/utils.R")
source("packages/arkbridge/R/help.R")

page <- .ark_render_help_page("lm")
if (is.null(page)) {
  stop("expected lm help page to render")
}

target <- NULL
for (reference in page$references) {
  if (identical(reference$label, "as.data.frame")) {
    target <- reference
    break
  }
}

if (is.null(target)) {
  stop("expected lm help to expose an as.data.frame reference")
}

target_name <- if (is.null(target$package) || !nzchar(target$package)) {
  target$topic
} else {
  paste0(target$package, "::", target$topic)
}

# This mirrors pressing Enter on the linked text in ArkHelp: the collected
# reference target must itself render as a help page.
linked_page <- .ark_render_help_page(target$topic, target$package)
if (is.null(linked_page) || !nzchar(linked_page$text)) {
  stop(sprintf("expected lm as.data.frame link target to resolve, got %s", target_name))
}

cat(target_name, "\n", sep = "")
]]

local output = vim.fn.systemlist({ "Rscript", "--vanilla", "-e", script })
if vim.v.shell_error ~= 0 then
  ark_test.fail("ArkHelp link target regression failed:\n" .. table.concat(output, "\n"))
end

if #output < 1 or output[1] == "" then
  ark_test.fail("expected ArkHelp link target regression to print the resolved target")
end

vim.print({ ark_help_link_targets_resolve = "ok", target = output[1] })
