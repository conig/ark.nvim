.ark_package_info_value <- function(description, field) {
  value <- description[[field]] %||% ""
  value <- as.character(value)
  if (length(value) < 1L || is.na(value[[1L]])) {
    return("")
  }

  gsub("[[:space:]]+", " ", trimws(value[[1L]]))
}

.ark_package_info_payload <- function(session, package) {
  package <- as.character(package %||% "")
  if (length(package) < 1L || !nzchar(package[[1L]])) {
    return(.emit_json(.new_error_payload(
      "E_IPC_REQUEST",
      "missing package",
      "ipc_request",
      session
    )))
  }

  package <- package[[1L]]

  tryCatch({
    description <- tryCatch(
      utils::packageDescription(package),
      error = function(e) NULL
    )

    if (is.null(description) || is.na(description$Package %||% NA_character_)) {
      return(.emit_json(list(
        schema_version = .ark_schema_version(),
        status = "ok",
        session = session,
        found = FALSE
      )))
    }

    description_file <- attr(description, "file", exact = TRUE) %||% ""
    lib_path <- ""
    if (nzchar(description_file)) {
      lib_path <- dirname(dirname(description_file))
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      found = TRUE,
      package = .ark_package_info_value(description, "Package"),
      title = .ark_package_info_value(description, "Title"),
      version = .ark_package_info_value(description, "Version"),
      description = .ark_package_info_value(description, "Description"),
      license = .ark_package_info_value(description, "License"),
      url = .ark_package_info_value(description, "URL"),
      lib_path = lib_path
    ))
  }, error = function(e) {
    .emit_json(.new_error_payload(
      "E_IPC_PACKAGE_INFO",
      conditionMessage(e),
      "ipc_package_info",
      session
    ))
  })
}
