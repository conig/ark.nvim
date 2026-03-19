.rscope_ipc_state <- new.env(parent = emptyenv())
.rscope_ipc_state$port <- NULL
.rscope_ipc_state$session <- list()
.rscope_ipc_state$running <- FALSE
.rscope_ipc_state$auth_token <- ""
.rscope_ipc_state$ipc_max_request_bytes <- as.integer(65536L)
.rscope_ipc_state$ipc_read_timeout_ms <- as.integer(250L)

.rscope_default_port <- function(session = list()) {
  pane <- session$tmux_pane %||% Sys.getenv("RSCOPE_TMUX_PANE", unset = "")
  pane_id <- suppressWarnings(as.integer(gsub("[^0-9]", "", pane)))
  if (is.na(pane_id)) {
    pane_id <- as.integer(Sys.getpid() %% 1000L)
  }

  as.integer(43000L + (pane_id %% 1000L))
}

.rscope_root_symbol <- function(expr) {
  parsed <- tryCatch(parse(text = expr, keep.source = FALSE), error = function(e) NULL)
  if (is.null(parsed) || length(parsed) == 0L) {
    return(NULL)
  }

  walk <- function(node) {
    if (is.symbol(node)) {
      return(as.character(node))
    }

    if (is.call(node)) {
      head <- as.character(node[[1L]])
      if (head %in% c("$", "@", "[[", "[", "::", ":::") && length(node) >= 2L) {
        return(walk(node[[2L]]))
      }
      if (length(node) >= 2L) {
        return(walk(node[[2L]]))
      }
    }

    NULL
  }

  walk(parsed[[length(parsed)]])
}

.rscope_is_internal_frame <- function(env) {
  ns <- tryCatch(asNamespace("rscope"), error = function(e) NULL)
  if (is.null(ns)) {
    return(FALSE)
  }
  identical(topenv(env), ns)
}

.rscope_resolve_eval_env <- function(expr, options = list()) {
  root <- .rscope_root_symbol(expr)
  explicit <- options$envir %||% NULL

  if (is.environment(explicit)) {
    if (is.null(root) || exists(root, envir = explicit, inherits = FALSE)) {
      return(explicit)
    }
  }

  frames <- sys.frames()
  if (length(frames) > 0L) {
    for (i in seq.int(length(frames), 1L, by = -1L)) {
      env <- frames[[i]]
      if (identical(env, baseenv()) || identical(env, emptyenv())) next
      if (.rscope_is_internal_frame(env)) next

      if (is.null(root)) {
        if (!identical(env, globalenv())) {
          return(env)
        }
      } else if (exists(root, envir = env, inherits = FALSE)) {
        return(env)
      }
    }
  }

  if (!is.null(root) && exists(root, envir = globalenv(), inherits = FALSE)) {
    return(globalenv())
  }

  if (is.environment(explicit)) {
    return(explicit)
  }

  globalenv()
}

.rscope_ping_payload <- function(session) {
  list(
    schema_version = .rscope_schema_version(),
    status = "ok",
    session = session
  )
}

.rscope_bootstrap_payload <- function(session) {
  tryCatch({
    envs <- lapply(search(), as.environment)
    search_path_symbols <- unique(unlist(lapply(envs, ls, all.names = TRUE), use.names = FALSE))
    library_paths <- base::.libPaths()

    .emit_json(list(
      schema_version = .rscope_schema_version(),
      status = "ok",
      session = session,
      search_path_symbols = as.character(search_path_symbols),
      library_paths = as.character(library_paths)
    ))
  }, error = function(e) {
    .emit_json(.new_error_payload(
      "E_IPC_BOOTSTRAP",
      conditionMessage(e),
      "ipc_bootstrap",
      session
    ))
  })
}

.rscope_request_meta_error <- function(code, message, stage, session) {
  .emit_json(.new_error_payload(code, message, stage, session))
}

.rscope_validate_request_meta <- function(req, session) {
  request_id <- req$request_id %||% ""
  if (!is.character(request_id) || length(request_id) != 1L || !nzchar(request_id)) {
    return(.rscope_request_meta_error("E_IPC_REQUEST", "missing request_id", "ipc_request", session))
  }

  required_token <- .rscope_ipc_state$auth_token %||% ""
  if (!is.character(required_token) || length(required_token) != 1L) {
    required_token <- ""
  }
  if (!nzchar(required_token)) {
    return(NULL)
  }

  auth_token <- req$auth_token %||% ""
  if (!is.character(auth_token) || length(auth_token) != 1L || !nzchar(auth_token) || !identical(auth_token, required_token)) {
    return(.rscope_request_meta_error("E_IPC_AUTH", "invalid IPC auth token", "ipc_auth", session))
  }

  NULL
}

.rscope_handle_ipc_request <- function(line) {
  req <- tryCatch(
    jsonlite::fromJSON(line, simplifyVector = FALSE),
    error = function(e) NULL
  )

  session <- .current_session(list(session = .rscope_ipc_state$session))
  if (is.null(req) || !is.list(req)) {
    return(.emit_json(.new_error_payload("E_IPC_DECODE", "invalid JSON request", "ipc_decode", session)))
  }

  req_meta_err <- .rscope_validate_request_meta(req, session)
  if (!is.null(req_meta_err)) {
    return(req_meta_err)
  }

  if (identical(req$command %||% "", "ping")) {
    return(.emit_json(.rscope_ping_payload(session)))
  }

  if (identical(req$command %||% "", "bootstrap")) {
    return(.rscope_bootstrap_payload(session))
  }

  expr <- req$expr %||% ""
  if (!is.character(expr) || length(expr) != 1L || !nzchar(expr)) {
    return(.emit_json(.new_error_payload("E_IPC_REQUEST", "missing expr", "ipc_request", session)))
  }

  options <- req$options %||% list()
  if (!is.list(options)) {
    options <- list()
  }

  options$session <- req$session %||% session
  options$envir <- .rscope_resolve_eval_env(expr, options)
  emit_menu(expr, options = options)
}

.rscope_dispatch_ipc_request <- function(line) {
  tryCatch(
    .rscope_handle_ipc_request(line),
    error = function(e) {
      .emit_json(
        .new_error_payload(
          "E_IPC_HANDLER",
          conditionMessage(e),
          "ipc_handler",
          .current_session(list(session = .rscope_ipc_state$session))
        )
      )
    }
  )
}

stop_ipc_service <- function() {
  if (isTRUE(.rscope_ipc_state$running)) {
    try(.Call("C_rscope_ipc_stop"), silent = TRUE)
  }

  .rscope_ipc_state$port <- NULL
  .rscope_ipc_state$session <- list()
  .rscope_ipc_state$running <- FALSE
  .rscope_ipc_state$auth_token <- ""
  invisible(TRUE)
}

.rscope_ipc_status <- function() {
  .Call("C_rscope_ipc_status")
}

start_ipc_service <- function(port = NULL, options = list(), force = FALSE) {
  session <- options$session %||% .current_session(options)
  auth_token <- options$auth_token %||% ""
  if (!is.character(auth_token) || length(auth_token) != 1L) {
    auth_token <- ""
  }
  if (!nzchar(auth_token) && isTRUE(.rscope_ipc_state$running) && is.character(.rscope_ipc_state$auth_token)) {
    auth_token <- .rscope_ipc_state$auth_token
  }
  max_request_bytes <- suppressWarnings(as.integer(options$ipc_max_request_bytes %||% 65536L))
  if (is.na(max_request_bytes) || max_request_bytes < 1024L) {
    max_request_bytes <- 65536L
  }
  read_timeout_ms <- suppressWarnings(as.integer(options$ipc_read_timeout_ms %||% 250L))
  if (is.na(read_timeout_ms) || read_timeout_ms < 10L) {
    read_timeout_ms <- 250L
  }

  try(.Call("C_rscope_ipc_config", as.integer(max_request_bytes), as.integer(read_timeout_ms)), silent = TRUE)

  if (is.null(port)) {
    port <- .rscope_default_port(session)
  }
  port <- as.integer(port)

  if (!isTRUE(force) &&
      isTRUE(.rscope_ipc_state$running) &&
      identical(.rscope_ipc_state$port, port)) {
    .rscope_ipc_state$auth_token <- auth_token
    .rscope_ipc_state$ipc_max_request_bytes <- as.integer(max_request_bytes)
    .rscope_ipc_state$ipc_read_timeout_ms <- as.integer(read_timeout_ms)
    return(list(host = "127.0.0.1", port = port, session = session, running = TRUE))
  }

  if (isTRUE(force) || !identical(.rscope_ipc_state$port, port)) {
    stop_ipc_service()
  }

  candidate_ports <- unique(as.integer(c(port, port + seq_len(16L))))
  bound_port <- NULL
  for (candidate in candidate_ports) {
    bound_port <- tryCatch(
      .Call("C_rscope_ipc_start", candidate, .rscope_dispatch_ipc_request),
      error = function(e) NULL
    )
    if (!is.null(bound_port)) {
      break
    }
  }

  if (is.null(bound_port)) {
    stop_ipc_service()
    stop(sprintf("failed to open IPC socket on port %d", port), call. = FALSE)
  }

  .rscope_ipc_state$port <- as.integer(bound_port)
  .rscope_ipc_state$session <- session
  .rscope_ipc_state$running <- TRUE
  .rscope_ipc_state$auth_token <- auth_token
  .rscope_ipc_state$ipc_max_request_bytes <- as.integer(max_request_bytes)
  .rscope_ipc_state$ipc_read_timeout_ms <- as.integer(read_timeout_ms)

  list(host = "127.0.0.1", port = .rscope_ipc_state$port, session = session, running = TRUE)
}
