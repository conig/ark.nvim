.ark_targets_error_payload <- function(session, code, message, stage) {
  .emit_json(.new_error_payload(code, message, stage, session))
}

.ark_targets_safe <- function(session, expr) {
  tryCatch(
    force(expr),
    error = function(e) {
      .ark_targets_error_payload(session, "E_IPC_TARGETS", conditionMessage(e), "ipc_targets")
    }
  )
}

.ark_targets_project <- function(root = "", script = "", store = "") {
  if (!is.character(root) || length(root) != 1L || !nzchar(root)) {
    root <- getwd()
  }
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)

  if (!is.character(script) || length(script) != 1L || !nzchar(script)) {
    script <- file.path(root, "_targets.R")
  }
  script <- normalizePath(script, winslash = "/", mustWork = FALSE)

  if (!is.character(store) || length(store) != 1L || !nzchar(store)) {
    store <- file.path(root, "_targets")
  }
  store <- normalizePath(store, winslash = "/", mustWork = FALSE)

  list(root = root, script = script, store = store)
}

.ark_targets_store_config <- function(script = "_targets.R") {
  if (!file.exists(script)) {
    return(NULL)
  }

  contents <- paste(readLines(script, warn = FALSE), collapse = "\n")
  match <- regexec(
    "(?s)(?:[A-Za-z.][A-Za-z0-9._]*(?:::|::))?tar_config_set\\s*\\([^)]*?\\bstore\\s*=\\s*[\"']([^\"']+)[\"']",
    contents,
    perl = TRUE
  )
  captures <- regmatches(contents, match)[[1L]]
  if (length(captures) < 2L || !nzchar(captures[[2L]])) {
    return(NULL)
  }

  captures[[2L]]
}

.ark_targets_project_from_cwd <- function() {
  root <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  script <- file.path(root, "_targets.R")
  store <- .ark_targets_store_config(script) %||% "_targets"
  if (!grepl("^(/|[A-Za-z]:[/\\\\])", store)) {
    store <- file.path(root, store)
  }

  .ark_targets_project(root, script, store)
}

.ark_targets_read_for_completion <- function(name) {
  if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
    stop("missing target name", call. = FALSE)
  }
  if (!.ark_targets_package_available()) {
    stop("the targets package is not installed in the managed R session", call. = FALSE)
  }

  project <- .ark_targets_project_from_cwd()
  .ark_targets_with_project(project, {
    .ark_targets_call_export("tar_read", list(name = name, store = project$store))
  })
}

.ark_targets_names <- function(names = character()) {
  names <- names %||% character()
  if (is.list(names)) {
    names <- unlist(names, recursive = TRUE, use.names = FALSE)
  }
  names <- as.character(names)
  names <- names[nzchar(names)]
  unique(names)
}

.ark_targets_package_available <- function() {
  requireNamespace("targets", quietly = TRUE)
}

.ark_targets_call_export <- function(name, args = list()) {
  if (!.ark_targets_package_available()) {
    stop("the targets package is not installed in the managed R session", call. = FALSE)
  }

  fun <- getExportedValue("targets", name)
  formals <- names(formals(fun))
  args <- args[names(args) %in% formals]
  do.call(fun, args)
}

.ark_targets_with_project <- function(project, expr) {
  old <- getwd()
  on.exit(setwd(old), add = TRUE)
  if (dir.exists(project$root)) {
    setwd(project$root)
  }
  force(expr)
}

.ark_targets_is_tar_target_call <- function(call) {
  if (!is.call(call) || length(call) < 3L) {
    return(FALSE)
  }

  head <- call[[1L]]
  if (is.symbol(head) && as.character(head) %in% c("tar_target", "tar_render")) {
    return(TRUE)
  }

  if (!is.call(head) || length(head) != 3L || !identical(as.character(head[[1L]]), "::")) {
    return(FALSE)
  }

  namespace <- as.character(head[[2L]])
  name <- as.character(head[[3L]])
  (identical(namespace, "targets") && identical(name, "tar_target")) ||
    (identical(namespace, "tarchetypes") && identical(name, "tar_render"))
}

.ark_targets_call_arg <- function(call, name) {
  names <- names(as.list(call))
  if (is.null(names)) {
    return(NULL)
  }

  index <- match(name, names)
  if (is.na(index)) {
    return(NULL)
  }

  call[[index]]
}

.ark_targets_deparse <- function(expr) {
  paste(deparse(expr, width.cutoff = 120L), collapse = "\n")
}

.ark_targets_walk_calls <- function(expr, visitor) {
  if (!is.call(expr) && !is.expression(expr)) {
    return(invisible(NULL))
  }

  visitor(expr)

  for (child in as.list(expr)) {
    .ark_targets_walk_calls(child, visitor)
  }

  invisible(NULL)
}

.ark_targets_static_manifest <- function(project) {
  if (!file.exists(project$script)) {
    return(list())
  }

  parsed <- parse(project$script, keep.source = FALSE)
  targets <- list()

  for (expr in parsed) {
    .ark_targets_walk_calls(expr, function(node) {
      if (!.ark_targets_is_tar_target_call(node)) {
        return(NULL)
      }

      name_expr <- node[[2L]]
      command_expr <- node[[3L]]
      name <- if (is.symbol(name_expr) || is.character(name_expr)) {
        as.character(name_expr)
      } else {
        .ark_targets_deparse(name_expr)
      }

      description_expr <- .ark_targets_call_arg(node, "description")
      description <- if (is.null(description_expr)) "" else as.character(description_expr)[[1L]]

      targets[[length(targets) + 1L]] <<- list(
        name = name,
        command = .ark_targets_deparse(command_expr),
        description = description,
        source = "static"
      )

      NULL
    })
  }

  targets
}

.ark_targets_static_network <- function(project) {
  manifest <- .ark_targets_static_manifest(project)
  target_names <- vapply(manifest, function(target) target$name %||% "", character(1))
  edges <- list()

  for (target in manifest) {
    command <- parse(text = target$command)
    symbols <- unique(all.names(command, functions = FALSE, unique = TRUE))
    upstream <- intersect(target_names, symbols)
    upstream <- setdiff(upstream, target$name)

    for (source in upstream) {
      edges[[length(edges) + 1L]] <- list(
        from = source,
        to = target$name,
        source = "static"
      )
    }
  }

  list(nodes = manifest, edges = edges, source = "static")
}

.ark_targets_as_records <- function(value) {
  if (is.null(value)) {
    return(list())
  }

  if (is.data.frame(value)) {
    rows <- seq_len(nrow(value))
    return(lapply(rows, function(index) {
      row <- value[index, , drop = FALSE]
      as.list(row)
    }))
  }

  if (is.list(value)) {
    return(value)
  }

  list()
}

.ark_targets_edge_records <- function(network) {
  if (is.null(network)) {
    return(list())
  }

  if (is.data.frame(network)) {
    return(.ark_targets_as_records(network))
  }

  if (is.list(network) && !is.null(network$edges)) {
    return(.ark_targets_as_records(network$edges))
  }

  list()
}

.ark_targets_downstream_names <- function(project, names) {
  names <- unique(as.character(names %||% character()))
  names <- names[nzchar(names)]
  if (!length(names)) {
    return(character())
  }

  network <- .ark_targets_static_network(project)
  if (!length(.ark_targets_edge_records(network)) && .ark_targets_package_available()) {
    network <- tryCatch(
      .ark_targets_with_project(project, {
        .ark_targets_call_export("tar_network", list(targets_only = TRUE, script = project$script))
      }),
      error = function(e) NULL
    )
  }

  edges <- .ark_targets_edge_records(network)
  if (!length(edges)) {
    return(names)
  }

  selected <- names
  repeat {
    downstream <- unique(unlist(lapply(edges, function(edge) {
      from <- as.character(edge$from %||% "")
      to <- as.character(edge$to %||% "")
      if (nzchar(from) && nzchar(to) && from %in% selected) {
        to
      } else {
        character()
      }
    }), use.names = FALSE))
    downstream <- downstream[nzchar(downstream)]
    next_selected <- unique(c(selected, downstream))
    if (length(next_selected) == length(selected)) {
      break
    }
    selected <- next_selected
  }

  selected
}

.ark_targets_progress_path <- function(project) {
  file.path(project$store, "meta", "progress")
}

.ark_targets_project_info_payload <- function(session, root = "", script = "", store = "") {
  .ark_targets_safe(session, {
    project <- .ark_targets_project(root, script, store)
    payload <- list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      project = project,
      targets_available = .ark_targets_package_available(),
      script_exists = file.exists(project$script),
      store_exists = dir.exists(project$store)
    )
    .emit_json(payload)
  })
}

.ark_targets_manifest_payload <- function(session, root = "", script = "", store = "") {
  .ark_targets_safe(session, {
    project <- .ark_targets_project(root, script, store)
    manifest <- NULL
    source <- "static"

    if (.ark_targets_package_available()) {
      manifest <- tryCatch(
        .ark_targets_with_project(project, {
          .ark_targets_call_export("tar_manifest", list(script = project$script))
        }),
        error = function(e) NULL
      )
      if (!is.null(manifest)) {
        source <- "targets"
      }
    }

    if (is.null(manifest)) {
      manifest <- .ark_targets_static_manifest(project)
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      project = project,
      source = source,
      targets = .ark_targets_as_records(manifest)
    ))
  })
}

.ark_targets_network_payload <- function(session, root = "", script = "", store = "") {
  .ark_targets_safe(session, {
    project <- .ark_targets_project(root, script, store)
    network <- NULL
    source <- "static"

    if (.ark_targets_package_available()) {
      network <- tryCatch(
        .ark_targets_with_project(project, {
          .ark_targets_call_export("tar_network", list(targets_only = TRUE, script = project$script))
        }),
        error = function(e) NULL
      )
      if (!is.null(network)) {
        source <- "targets"
      }
    }

    if (is.null(network)) {
      network <- .ark_targets_static_network(project)
    }

    if (is.data.frame(network)) {
      network <- list(edges = .ark_targets_as_records(network))
    }

    .emit_json(c(
      list(
        schema_version = .ark_schema_version(),
        status = "ok",
        session = session,
        project = project,
        source = source
      ),
      network
    ))
  })
}

.ark_targets_meta_payload <- function(session, root = "", script = "", store = "", names = character()) {
  .ark_targets_safe(session, {
    names <- .ark_targets_names(names)
    project <- .ark_targets_project(root, script, store)
    meta <- .ark_targets_with_project(project, {
      .ark_targets_call_export("tar_meta", list(names = names, store = project$store))
    })

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      project = project,
      meta = .ark_targets_as_records(meta)
    ))
  })
}

.ark_targets_object_meta_payload <- function(session, root = "", script = "", store = "", name = "") {
  .ark_targets_safe(session, {
    if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
      return(.ark_targets_error_payload(session, "E_IPC_REQUEST", "missing target name", "ipc_targets_object_meta"))
    }

    project <- .ark_targets_project(root, script, store)
    value <- .ark_targets_with_project(project, {
      .ark_targets_call_export("tar_read", list(name = name, store = project$store))
    })

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      project = project,
      name = name,
      object_meta = inspect_object(value, options = list(
        request_profile = "meta_only",
        max_members = 200L,
        include_member_stats = FALSE
      ))
    ))
  })
}

.ark_targets_action_payload <- function(session, action = "", root = "", script = "", store = "", names = character()) {
  .ark_targets_safe(session, {
    if (!is.character(action) || length(action) != 1L || !nzchar(action)) {
      return(.ark_targets_error_payload(session, "E_IPC_REQUEST", "missing targets action", "ipc_targets_action"))
    }

    names <- .ark_targets_names(names)
    project <- .ark_targets_project(root, script, store)
    action <- match.arg(action, c("make", "make_downstream", "invalidate", "load"))
    resolved_names <- if (identical(action, "make_downstream")) {
      .ark_targets_downstream_names(project, names)
    } else {
      names
    }

    result <- .ark_targets_with_project(project, {
      if (identical(action, "make") || identical(action, "make_downstream")) {
        .ark_targets_call_export("tar_make", list(names = resolved_names, script = project$script, store = project$store))
      } else if (identical(action, "invalidate")) {
        .ark_targets_call_export("tar_invalidate", list(names = names, store = project$store))
      } else {
        .ark_targets_call_export("tar_load", list(names = names, store = project$store))
      }
    })

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      project = project,
      action = action,
      names = names,
      resolved_names = resolved_names,
      log_path = .ark_targets_progress_path(project),
      result = result
    ))
  })
}
