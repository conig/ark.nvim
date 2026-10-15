# Read a real failed-target workspace through the standalone worker. The source
# script is replaced with a failing sentinel to prove inspection never sources it.
args <- commandArgs(trailingOnly = TRUE)
repo <- normalizePath(if (length(args)) args[[1L]] else ".")
main <- function() {
  root <- tempfile("ark-target-traceback-test-")
  dir.create(root)
  old <- setwd(root)
  on.exit({ setwd(old); unlink(root, recursive = TRUE) }, add = TRUE)
  script <- file.path(root, "_targets.R")
  writeLines(c(
    "library(targets)",
    "tar_option_set(workspace_on_error = TRUE)",
    "list(tar_target(broken, stop('saved traceback fixture')))"
  ), script)
  tryCatch(targets::tar_make(callr_function = NULL, reporter = "silent"), error = function(error) NULL)
  stopifnot("broken" %in% targets::tar_workspaces(store = file.path(root, "_targets")))
  writeLines("stop('traceback must never evaluate the pipeline script')", script)
  result <- file.path(root, "result.json")
  request <- jsonlite::toJSON(list(name = "broken", store = file.path(root, "_targets")), auto_unbox = TRUE)
  status <- system2(file.path(R.home("bin"), "R"), c("--slave", "--vanilla", "-f", shQuote(file.path(repo, "scripts/ark-target-traceback.R")), "--args", shQuote(request), shQuote(result)))
  payload <- jsonlite::fromJSON(result, simplifyVector = FALSE)
  stopifnot(status == 0L, payload$status == "ok", payload$available)
  stopifnot(any(vapply(payload$frames, function(frame) grepl("saved traceback fixture", frame$call, fixed = TRUE), logical(1))))
  stopifnot(all(vapply(payload$frames, function(frame) is.null(frame$path), logical(1))))
  cat("saved target traceback without script evaluation: ok\n")
}
main()
