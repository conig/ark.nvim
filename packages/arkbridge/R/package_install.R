.ark_package_install_error_payload <- function(session, code, message, stage) {
  .emit_json(.new_error_payload(code, message, stage, session))
}

.ark_package_install_safe <- function(session, expr) {
  tryCatch(
    force(expr),
    error = function(e) {
      .ark_package_install_error_payload(session, "E_IPC_PACKAGE_INSTALL", conditionMessage(e), "ipc_package_install")
    }
  )
}

.ark_package_install_names <- function(packages) {
  packages <- packages %||% character()
  if (is.list(packages)) {
    packages <- unlist(packages, recursive = TRUE, use.names = FALSE)
  }

  packages <- trimws(as.character(packages))
  packages <- packages[nzchar(packages)]
  unique(packages)
}

.ark_description_path <- function(description = "") {
  description <- description %||% ""
  if (!is.character(description) || length(description) != 1L || !nzchar(description)) {
    return("")
  }

  if (dir.exists(description)) {
    description <- file.path(description, "DESCRIPTION")
  }

  if (!file.exists(description)) {
    return("")
  }

  normalizePath(description, winslash = "/", mustWork = TRUE)
}

.ark_description_field <- function(description, field) {
  if (!nzchar(description)) {
    return("")
  }

  dcf <- tryCatch(
    read.dcf(description, all = TRUE),
    error = function(e) NULL
  )
  if (is.null(dcf) || nrow(dcf) < 1L || !field %in% colnames(dcf)) {
    return("")
  }

  value <- dcf[1L, field]
  value <- as.character(value)
  if (length(value) < 1L || is.na(value[[1L]])) {
    return("")
  }

  value[[1L]]
}

.ark_split_description_list <- function(value) {
  if (!is.character(value) || length(value) < 1L || !nzchar(value[[1L]])) {
    return(character())
  }

  entries <- unlist(strsplit(value[[1L]], ",", fixed = TRUE), use.names = FALSE)
  entries <- trimws(entries)
  entries[nzchar(entries)]
}

.ark_remote_package_name <- function(spec) {
  spec <- trimws(as.character(spec %||% ""))
  if (!nzchar(spec)) {
    return(NULL)
  }

  named <- regexec("^([A-Za-z][A-Za-z0-9.]*)\\s*=\\s*(.+)$", spec, perl = TRUE)
  named_match <- regmatches(spec, named)[[1L]]
  if (length(named_match) == 3L && nzchar(named_match[[2L]]) && nzchar(named_match[[3L]])) {
    return(list(package = named_match[[2L]], spec = trimws(named_match[[3L]])))
  }

  ref <- sub("^[A-Za-z][A-Za-z0-9.]*::", "", spec, perl = TRUE)
  ref <- sub("^git::", "", ref, perl = TRUE)
  ref <- sub("^https?://github[.]com/", "", ref, perl = TRUE)
  ref <- sub("[?#].*$", "", ref, perl = TRUE)
  ref <- sub("@.*$", "", ref, perl = TRUE)
  ref <- sub("[.]git$", "", ref, perl = TRUE)

  parts <- strsplit(ref, "/", fixed = TRUE)[[1L]]
  parts <- parts[nzchar(parts)]
  if (length(parts) < 2L) {
    return(NULL)
  }

  package <- parts[[length(parts)]]
  package <- sub("[.]git$", "", package, perl = TRUE)
  if (!nzchar(package)) {
    return(NULL)
  }

  list(package = package, spec = spec)
}

.ark_description_remote_specs <- function(description = "") {
  description <- .ark_description_path(description)
  remotes <- .ark_split_description_list(.ark_description_field(description, "Remotes"))
  specs <- character()

  for (remote in remotes) {
    parsed <- .ark_remote_package_name(remote)
    if (is.null(parsed)) {
      next
    }
    specs[[parsed$package]] <- parsed$spec
  }

  specs
}

.ark_package_install_specs <- function(packages, description = "") {
  packages <- .ark_package_install_names(packages)
  remote_specs <- .ark_description_remote_specs(description)

  specs <- packages
  for (i in seq_along(packages)) {
    remote_spec <- unname(remote_specs[packages[[i]]])
    if (length(remote_spec) == 1L && !is.na(remote_spec) && nzchar(remote_spec)) {
      specs[[i]] <- remote_spec
    }
  }

  specs
}

.ark_package_install_method <- function() {
  if (requireNamespace("pak", quietly = TRUE)) {
    return("pak")
  }

  "utils"
}

.ark_package_install_run <- function(packages, specs, method) {
  if (identical(method, "pak")) {
    pak::pkg_install(specs, upgrade = FALSE, ask = FALSE, dependencies = NA)
    return(invisible(TRUE))
  }

  remote <- specs[specs != packages]
  if (length(remote) > 0L) {
    stop(
      "pak is required to install non-CRAN package specs from DESCRIPTION: ",
      paste(remote, collapse = ", "),
      call. = FALSE
    )
  }

  utils::install.packages(packages)
  invisible(TRUE)
}

.ark_package_install_payload <- function(session, packages = character(), description = "", dry_run = FALSE) {
  .ark_package_install_safe(session, {
    packages <- .ark_package_install_names(packages)
    if (length(packages) < 1L) {
      return(.ark_package_install_error_payload(session, "E_IPC_REQUEST", "missing packages", "ipc_package_install"))
    }

    description <- .ark_description_path(description)
    specs <- .ark_package_install_specs(packages, description)
    method <- .ark_package_install_method()

    if (!isTRUE(dry_run)) {
      .ark_package_install_run(packages, specs, method)
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      method = method,
      packages = packages,
      specs = specs,
      description = description,
      dry_run = isTRUE(dry_run)
    ))
  })
}
