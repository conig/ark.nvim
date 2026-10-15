# Explicit, bounded inspection only: do not install an error handler, evaluate
# stack calls, inspect frame environments, or add traceback text to diagnostics.
.ark_traceback_location <- function(frame) {
  ref <- attr(frame, "srcref", exact = TRUE)
  if (!inherits(ref, "srcref") || length(ref) < 1L || !is.numeric(ref)) {
    return(list())
  }
  src <- attr(ref, "srcfile", exact = TRUE)
  if (!is.environment(src) || !isTRUE(get0("isFile", src, inherits = FALSE))) {
    return(list())
  }
  path <- get0("filename", src, inherits = FALSE)
  wd <- get0("wd", src, inherits = FALSE)
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    return(list())
  }
  if (!startsWith(path, "/")) {
    if (!is.character(wd) || length(wd) != 1L || is.na(wd) || !startsWith(wd, "/")) {
      return(list())
    }
    path <- file.path(wd, path)
  }
  line <- as.integer(ref[[1L]])
  if (is.na(line) || line < 1L || !file.exists(path)) {
    return(list())
  }
  # srcfile character columns are not byte offsets; use the genuine line only.
  list(path = normalizePath(path, mustWork = TRUE), line = line)
}

.ark_traceback_data <- function(trace) {
  if (is.pairlist(trace)) {
    trace <- as.list(trace)
  }
  if (!is.list(trace)) {
    trace <- list()
  }
  count <- length(trace)
  frames <- lapply(seq_len(min(count, 128L)), function(index) {
    frame <- trace[[index]]
    text <- if (is.character(frame)) {
      paste(substr(utils::head(frame, 8L), 1L, 1000L), collapse = " ")
    } else if (is.language(frame)) {
      paste(deparse(frame, width.cutoff = 120L, nlines = 8L), collapse = " ")
    } else {
      "<call unavailable>"
    }
    truncated <- nchar(text) > 1000L
    text <- paste0(substr(text, 1L, 1000L), if (truncated) "\u2026" else "")
    c(list(index = count - index + 1L, call = text), .ark_traceback_location(frame))
  })
  list(available = count > 0L, frames = frames, truncated = count > 128L)
}

.ark_error_traceback_payload <- function(session) {
  tryCatch({
    # R >= 4.2 keeps the last *uncaught* stack here. Do not call .traceback(n),
    # which obtains the current bridge stack, nor traceback(), which prints it.
    # Read the raw stack so frame limits apply before potentially costly deparse.
    trace <- get0(".Traceback", envir = baseenv(), inherits = FALSE)
    data <- .ark_traceback_data(trace)
    .emit_json(c(list(
      schema_version = .ark_schema_version(),
      product_version = .ark_product_version(),
      status = "ok",
      session = session,
      source = "last_uncaught_error"
    ), data))
  }, error = function(error) {
    .emit_json(.new_error_payload("E_IPC_TRACEBACK", conditionMessage(error), "ipc_traceback", session))
  })
}
