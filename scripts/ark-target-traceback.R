#!/usr/bin/env Rscript
# Explicit saved-workspace inspection in a disposable process. Never source the
# pipeline or load a workspace into the user's interactive R session.
Sys.umask("0077")
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) quit(status = 2L)
request <- jsonlite::fromJSON(args[[1L]])
result <- tryCatch({
  if (!requireNamespace("targets", quietly = TRUE)) stop("targets is not installed")
  name <- request$name
  store <- request$store
  if (!is.character(name) || length(name) != 1L || !nzchar(name)) stop("A target name is required")
  if (!is.character(store) || length(store) != 1L || !nzchar(store)) stop("A targets store is required")
  if (!name %in% targets::tar_workspaces(store = store)) {
    list(status = "ok", available = FALSE, frames = list(), source = "target_workspace",
      message = "No saved workspace for this target. Enable workspace_on_error before a future build.")
  } else {
    trace <- eval(substitute(targets::tar_traceback(TARGET, store = STORE),
      list(TARGET = as.name(name), STORE = store)))
    # The public targets API returns call text, not source references. Do not
    # parse strings that resemble filenames into invented navigation locations.
    frames <- lapply(seq_len(min(length(trace), 128L)), function(index) {
      text <- as.character(trace[[index]])
      list(index = index, call = paste0(substr(text, 1L, 1000L), if (nchar(text) > 1000L) "…" else ""))
    })
    list(status = "ok", available = length(frames) > 0L, frames = frames,
      truncated = length(trace) > 128L, source = "target_workspace")
  }
}, error = function(error) list(status = "error", message = conditionMessage(error)))
writeLines(jsonlite::toJSON(result, auto_unbox = TRUE, null = "null"), args[[2L]], useBytes = TRUE)
