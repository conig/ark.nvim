args <- commandArgs(trailingOnly = TRUE)

pkg_path <- if (length(args) >= 1L) args[[1]] else ""
lib_path <- if (length(args) >= 2L) args[[2]] else ""
stamp_path <- if (length(args) >= 3L) args[[3]] else ""
source_mtime <- suppressWarnings(as.integer(if (length(args) >= 4L) args[[4]] else "0"))

if (!nzchar(pkg_path) || !dir.exists(pkg_path)) {
  stop("missing arkbridge package source path", call. = FALSE)
}

if (!nzchar(lib_path)) {
  stop("missing arkbridge install library path", call. = FALSE)
}

dir.create(lib_path, recursive = TRUE, showWarnings = FALSE)

lock_dir <- file.path(lib_path, "00LOCK-arkbridge")
if (dir.exists(lock_dir)) {
  info <- tryCatch(file.info(lock_dir), error = function(e) NULL)
  lock_age_seconds <- if (!is.null(info) && nrow(info) > 0L && !is.na(info$mtime[[1]])) {
    as.numeric(difftime(Sys.time(), info$mtime[[1]], units = "secs"))
  } else {
    0
  }

  if (is.finite(lock_age_seconds) && lock_age_seconds >= 600) {
    unlink(lock_dir, recursive = TRUE, force = TRUE)
  }
}

.libPaths(unique(c(lib_path, .libPaths())))
utils::install.packages(pkg_path, repos = NULL, type = "source", lib = lib_path, quiet = TRUE)

installed_path <- tryCatch(find.package("arkbridge", lib.loc = lib_path), error = function(e) "")
if (!nzchar(installed_path)) {
  stop("arkbridge install completed without an installed package path", call. = FALSE)
}

stamp_dir <- dirname(stamp_path)
dir.create(stamp_dir, recursive = TRUE, showWarnings = FALSE)

payload <- list(
  source_mtime = if (is.finite(source_mtime)) as.integer(source_mtime) else 0L,
  installed_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3%z"),
  installed_path = normalizePath(installed_path, winslash = "/", mustWork = FALSE)
)

tmp_path <- tempfile("arkbridge-install-", tmpdir = stamp_dir, fileext = ".json")
writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = FALSE), tmp_path, useBytes = TRUE)
file.rename(tmp_path, stamp_path)
