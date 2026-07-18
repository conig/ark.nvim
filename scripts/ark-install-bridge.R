args <- commandArgs(trailingOnly = TRUE)

pkg_path <- if (length(args) >= 1L) args[[1]] else ""
lib_path <- if (length(args) >= 2L) args[[2]] else ""
stamp_path <- if (length(args) >= 3L) args[[3]] else ""
source_mtime <- suppressWarnings(as.integer(if (length(args) >= 4L) args[[4]] else "0"))
runtime_revision <- suppressWarnings(as.integer(if (length(args) >= 5L) args[[5]] else "0"))
dependency_repo <- if (length(args) >= 6L) args[[6]] else ""

if (!nzchar(pkg_path) || !dir.exists(pkg_path)) {
  stop("missing arkbridge package source path", call. = FALSE)
}

if (!nzchar(lib_path)) {
  stop("missing arkbridge install library path", call. = FALSE)
}

dir.create(lib_path, recursive = TRUE, showWarnings = FALSE)

lock_dir <- file.path(lib_path, "00LOCK-arkbridge")
install_succeeded <- FALSE
on.exit({
  if (!isTRUE(install_succeeded) && dir.exists(lock_dir)) {
    unlink(lock_dir, recursive = TRUE, force = TRUE)
  }
}, add = TRUE)

lock_age_seconds <- function(path) {
  info <- tryCatch(file.info(path), error = function(e) NULL)
  if (!is.null(info) && nrow(info) > 0L && !is.na(info$mtime[[1]])) {
    return(as.numeric(difftime(Sys.time(), info$mtime[[1]], units = "secs")))
  }

  0
}

clear_install_lock <- function(path) {
  if (!dir.exists(path)) {
    return(invisible(TRUE))
  }

  age <- lock_age_seconds(path)
  if (is.finite(age) && age < 600) {
    deadline <- Sys.time() + 2
    while (dir.exists(path) && Sys.time() < deadline) {
      Sys.sleep(0.1)
    }
  }

  if (dir.exists(path)) {
    unlink(path, recursive = TRUE, force = TRUE)
  }

  invisible(!dir.exists(path))
}

clear_install_lock(lock_dir)

.libPaths(unique(c(lib_path, .libPaths())))

if (!requireNamespace("jsonlite", quietly = TRUE)) {
  if (!nzchar(dependency_repo)) {
    stop(
      paste0(
        "R package `jsonlite` is required to install arkbridge; ",
        "run scripts/ark-setup or install.packages('jsonlite')"
      ),
      call. = FALSE
    )
  }

  message("Installing missing R dependency `jsonlite` into ", lib_path)
  utils::install.packages(
    "jsonlite",
    repos = dependency_repo,
    lib = lib_path
  )
}

if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("jsonlite installation completed but the namespace is unavailable", call. = FALSE)
}

if (!is.finite(source_mtime) || source_mtime <= 0L) {
  source_files <- list.files(
    pkg_path,
    all.files = TRUE,
    full.names = TRUE,
    recursive = TRUE,
    no.. = TRUE
  )
  source_info <- file.info(source_files)
  source_times <- as.numeric(source_info$mtime)
  source_times <- source_times[is.finite(source_times)]
  source_mtime <- if (length(source_times) > 0L) {
    as.integer(max(source_times))
  } else {
    0L
  }
}

installed_path <- tryCatch(find.package("arkbridge", lib.loc = lib_path), error = function(e) "")
if (nzchar(installed_path) && file.exists(stamp_path)) {
  installed_stamp <- tryCatch(
    jsonlite::fromJSON(stamp_path, simplifyVector = TRUE),
    error = function(e) NULL
  )
  if (
    is.list(installed_stamp) &&
      identical(as.integer(installed_stamp$source_mtime), as.integer(source_mtime)) &&
      identical(as.integer(installed_stamp$runtime_revision), as.integer(runtime_revision))
  ) {
    quit(save = "no", status = 0L, runLast = FALSE)
  }
}

old_warn <- getOption("warn")
options(warn = 2)
on.exit(options(warn = old_warn), add = TRUE)
utils::install.packages(
  pkg_path,
  repos = NULL,
  type = "source",
  lib = lib_path,
  quiet = TRUE,
  INSTALL_opts = c("--preclean", "--clean")
)
install_succeeded <- TRUE

installed_path <- tryCatch(find.package("arkbridge", lib.loc = lib_path), error = function(e) "")
if (!nzchar(installed_path)) {
  stop("arkbridge install completed without an installed package path", call. = FALSE)
}

stamp_dir <- dirname(stamp_path)
dir.create(stamp_dir, recursive = TRUE, showWarnings = FALSE)

payload <- list(
  source_mtime = if (is.finite(source_mtime)) as.integer(source_mtime) else 0L,
  runtime_revision = if (is.finite(runtime_revision)) as.integer(runtime_revision) else 0L,
  installed_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3%z"),
  installed_path = normalizePath(installed_path, winslash = "/", mustWork = FALSE)
)

tmp_path <- tempfile("arkbridge-install-", tmpdir = stamp_dir, fileext = ".json")
writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = FALSE), tmp_path, useBytes = TRUE)
if (!file.rename(tmp_path, stamp_path)) {
  stop("failed to publish arkbridge install stamp", call. = FALSE)
}
