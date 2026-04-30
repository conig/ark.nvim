.ark_view_error_payload <- function(session, code, message, stage) {
  .emit_json(.new_error_payload(code, message, stage, session))
}

.ark_view_generate_id <- function() {
  paste0(
    "view-",
    as.integer(Sys.getpid()),
    "-",
    format(as.integer(as.numeric(Sys.time()) * 1000), scientific = FALSE),
    "-",
    paste(sample(c(letters, LETTERS, 0:9), 8L, replace = TRUE), collapse = "")
  )
}

.ark_view_require_session_id <- function(session, session_id) {
  if (!is.character(session_id) || length(session_id) != 1L || !nzchar(session_id)) {
    stop(structure(
      list(code = "E_IPC_REQUEST", message = "missing session_id", stage = "ipc_request"),
      class = "ark_view_error"
    ))
  }

  if (!exists(session_id, envir = .ark_ipc_state$views, inherits = FALSE)) {
    stop(structure(
      list(code = "E_IPC_VIEW_GONE", message = "view session not found", stage = "ipc_view"),
      class = "ark_view_error"
    ))
  }

  get(session_id, envir = .ark_ipc_state$views, inherits = FALSE)
}

.ark_view_fail <- function(code, message, stage) {
  stop(structure(
    list(code = as.character(code), message = as.character(message), stage = as.character(stage)),
    class = "ark_view_error"
  ))
}

.ark_view_safe <- function(session, expr) {
  tryCatch(
    expr,
    ark_view_error = function(e) {
      .ark_view_error_payload(session, e$code %||% "E_IPC_VIEW", e$message %||% "view request failed", e$stage %||% "ipc_view")
    },
    error = function(e) {
      .ark_view_error_payload(session, "E_IPC_VIEW", conditionMessage(e), "ipc_view")
    }
  )
}

.ark_view_normalize_title <- function(expr) {
  root <- .ark_root_symbol(expr)
  if (is.character(root) && length(root) == 1L && nzchar(root)) {
    return(root)
  }
  expr
}

.ark_view_escape_code_string <- function(x) {
  encodeString(as.character(x %||% ""), quote = "\"")
}

.ark_view_column_accessor <- function(name) {
  sprintf("[[%s]]", .ark_view_escape_code_string(name))
}

.ark_view_is_rectangular <- function(x) {
  if (is.data.frame(x)) {
    return(TRUE)
  }

  dims <- dim(x)
  is.atomic(x) && length(dims) == 2L
}

.ark_view_as_table <- function(x) {
  if (is.data.frame(x)) {
    return(x)
  }

  if (.ark_view_is_rectangular(x)) {
    out <- as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE)
    names(out) <- colnames(x) %||% paste0("V", seq_len(ncol(out)))
    return(out)
  }

  .ark_view_fail(
    "E_IPC_VIEW_TYPE",
    sprintf("unsupported object for ArkView: %s", paste(class(x), collapse = "/")),
    "ipc_view_open"
  )
}

.ark_view_stringify_value <- function(value, max_chars = 80L) {
  if (is.null(value) || length(value) == 0L) {
    return("")
  }

  if (is.list(value) && !is.object(value)) {
    value <- value[[1L]]
  }

  txt <- tryCatch({
    if (length(value) == 1L && !is.list(value)) {
      paste(format(value, trim = TRUE, justify = "none"), collapse = " ")
    } else {
      paste(utils::capture.output(str(value, give.attr = FALSE, vec.len = 3L)), collapse = " ")
    }
  }, error = function(e) {
    paste(as.character(value), collapse = " ")
  })

  txt <- gsub("[\r\n\t]+", " ", txt)
  txt <- trimws(txt)
  if (!nzchar(txt)) {
    txt <- paste(as.character(value), collapse = " ")
  }

  if (nchar(txt, type = "bytes") > max_chars) {
    paste0(substr(txt, 1L, max_chars - 3L), "...")
  } else {
    txt
  }
}

.ark_view_schema <- function(data) {
  lapply(seq_along(data), function(index) {
    column <- data[[index]]
    list(
      index = as.integer(index),
      name = names(data)[[index]] %||% paste0("V", index),
      type = typeof(column),
      class = paste(class(column), collapse = "/"),
      sortable = TRUE,
      filterable = TRUE
    )
  })
}

.ark_view_apply_filters <- function(data, filters) {
  if (!length(filters)) {
    return(data)
  }

  keep <- rep(TRUE, nrow(data))
  for (name in names(filters)) {
    query <- filters[[name]]
    if (!is.character(query) || !nzchar(query)) {
      next
    }

    index <- suppressWarnings(as.integer(name))
    if (is.na(index) || index < 1L || index > ncol(data)) {
      next
    }

    values <- vapply(data[[index]], .ark_view_stringify_value, character(1))
    matches <- grepl(query, values, fixed = TRUE, ignore.case = TRUE)
    matches[is.na(matches)] <- FALSE
    keep <- keep & matches
  }

  data[keep, , drop = FALSE]
}

.ark_view_apply_sort <- function(data, sort_state) {
  if (!is.list(sort_state)) {
    return(data)
  }

  column_index <- suppressWarnings(as.integer(sort_state$column_index %||% NA_integer_))
  direction <- as.character(sort_state$direction %||% "")
  if (is.na(column_index) || column_index < 1L || column_index > ncol(data) || !direction %in% c("asc", "desc")) {
    return(data)
  }

  values <- data[[column_index]]
  ord <- order(values, na.last = TRUE, decreasing = identical(direction, "desc"))
  data[ord, , drop = FALSE]
}

.ark_view_current_data <- function(view) {
  data <- view$data
  data <- .ark_view_apply_filters(data, view$filters %||% list())
  .ark_view_apply_sort(data, view$sort %||% list())
}

.ark_view_state_payload_data <- function(view) {
  data <- .ark_view_current_data(view)
  filters <- view$filters %||% list()
  filter_list <- lapply(names(filters), function(name) {
    list(column_index = suppressWarnings(as.integer(name)), query = filters[[name]])
  })
  list(
    session_id = view$session_id,
    title = view$title,
    source_label = view$expr,
    total_rows = as.integer(nrow(data)),
    total_columns = as.integer(ncol(data)),
    schema = .ark_view_schema(view$data),
    sort = list(
      column_index = as.integer(view$sort$column_index %||% 0L),
      direction = as.character(view$sort$direction %||% "")
    ),
    filters = filter_list
  )
}

.ark_view_open_payload <- function(session, expr, options = list()) {
  .ark_view_safe(session, {
    env <- .ark_resolve_eval_env(expr, options)
    object <- eval(parse(text = expr, keep.source = FALSE), envir = env)
    data <- .ark_view_as_table(object)
    session_id <- .ark_view_generate_id()
    view <- list(
      session_id = session_id,
      expr = expr,
      title = .ark_view_normalize_title(expr),
      data = data,
      filters = list(),
      sort = list(column_index = 0L, direction = "")
    )
    assign(session_id, view, envir = .ark_ipc_state$views)

    .emit_json(utils::modifyList(
      list(
        schema_version = .ark_schema_version(),
        status = "ok",
        session = session
      ),
      .ark_view_state_payload_data(view)
    ))
  })
}

.ark_view_state_payload <- function(session, session_id) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    .emit_json(utils::modifyList(
      list(schema_version = .ark_schema_version(), status = "ok", session = session),
      .ark_view_state_payload_data(view)
    ))
  })
}

.ark_view_page_payload <- function(session, session_id, offset = 0L, limit = 200L) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    data <- .ark_view_current_data(view)
    offset <- suppressWarnings(as.integer(offset))
    limit <- suppressWarnings(as.integer(limit))
    if (is.na(offset) || offset < 0L) offset <- 0L
    if (is.na(limit) || limit < 1L) limit <- 200L

    total_rows <- nrow(data)
    if (offset >= total_rows) {
      page <- data[0, , drop = FALSE]
      row_numbers <- integer()
    } else {
      end <- min(total_rows, offset + limit)
      rows <- seq.int(offset + 1L, end)
      page <- data[rows, , drop = FALSE]
      row_numbers <- rows
    }

    page_rows <- lapply(seq_len(nrow(page)), function(index) {
      row <- page[index, , drop = FALSE]
      unname(vapply(seq_len(ncol(row)), function(column_index) {
        .ark_view_stringify_value(row[[column_index]][[1L]])
      }, character(1)))
    })

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      offset = as.integer(offset),
      limit = as.integer(limit),
      total_rows = as.integer(total_rows),
      row_numbers = as.integer(row_numbers),
      rows = page_rows
    ))
  })
}

.ark_view_sort_payload <- function(session, session_id, column_index, direction) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    column_index <- suppressWarnings(as.integer(column_index))
    direction <- as.character(direction %||% "")
    if (is.na(column_index) || column_index < 1L || column_index > ncol(view$data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid column_index", "ipc_view_sort")
    }
    if (!direction %in% c("", "asc", "desc")) {
      .ark_view_fail("E_IPC_REQUEST", "invalid sort direction", "ipc_view_sort")
    }

    view$sort <- list(
      column_index = if (nzchar(direction)) column_index else 0L,
      direction = direction
    )
    assign(session_id, view, envir = .ark_ipc_state$views)
    .emit_json(utils::modifyList(
      list(schema_version = .ark_schema_version(), status = "ok", session = session),
      .ark_view_state_payload_data(view)
    ))
  })
}

.ark_view_filter_payload <- function(session, session_id, column_index, query) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    column_index <- suppressWarnings(as.integer(column_index))
    query <- as.character(query %||% "")
    if (is.na(column_index) || column_index < 1L || column_index > ncol(view$data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid column_index", "ipc_view_filter")
    }

    filters <- view$filters %||% list()
    key <- as.character(column_index)
    if (nzchar(query)) {
      filters[[key]] <- query
    } else {
      filters[[key]] <- NULL
    }
    view$filters <- filters
    assign(session_id, view, envir = .ark_ipc_state$views)
    .emit_json(utils::modifyList(
      list(schema_version = .ark_schema_version(), status = "ok", session = session),
      .ark_view_state_payload_data(view)
    ))
  })
}

.ark_view_schema_search_payload <- function(session, session_id, query) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    schema <- .ark_view_schema(view$data)
    query <- trimws(as.character(query %||% ""))
    matches <- Filter(function(item) {
      if (!nzchar(query)) {
        return(TRUE)
      }
      grepl(query, item$name, fixed = TRUE, ignore.case = TRUE) ||
        grepl(query, item$class, fixed = TRUE, ignore.case = TRUE) ||
        grepl(query, item$type, fixed = TRUE, ignore.case = TRUE)
    }, schema)

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      matches = matches
    ))
  })
}

.ark_view_profile_text <- function(column, name) {
  value_labels <- vapply(seq_along(column), function(index) {
    value <- column[[index]]
    if (length(value) == 1L && is.atomic(value) && is.na(value)) {
      return("<NA>")
    }
    .ark_view_stringify_value(value, max_chars = 40L)
  }, character(1))
  non_missing_labels <- value_labels[value_labels != "<NA>"]
  unique_count <- length(unique(non_missing_labels))

  lines <- c(
    sprintf("# %s", name),
    "",
    sprintf("Type: %s", typeof(column)),
    sprintf("Class: %s", paste(class(column), collapse = "/")),
    sprintf("Rows: %d", length(column)),
    sprintf("Missing: %d", sum(is.na(column))),
    sprintf("Unique values: %d", unique_count)
  )

  if (is.numeric(column)) {
    numeric_values <- suppressWarnings(as.numeric(column))
    numeric_values <- numeric_values[is.finite(numeric_values)]
    if (length(numeric_values)) {
      stats <- stats::quantile(numeric_values, probs = c(0, 0.25, 0.5, 0.75, 1), names = TRUE)
      names(stats) <- c("Min", "Q1", "Median", "Q3", "Max")
      lines <- c(lines, "", "Summary:", paste(names(stats), stats, sep = ": "))
    } else {
      lines <- c(lines, "", "Summary:", "no finite values")
    }
    lines <- c(lines, "", "Distribution:", .ark_view_numeric_distribution_lines(column))
  }

  top <- sort(table(value_labels, useNA = "no"), decreasing = TRUE)
  if (length(top) > 5L) {
    top <- top[seq_len(5L)]
  }
  if (length(top)) {
    lines <- c(lines, "", "Top values:", paste(names(top), as.integer(top), sep = ": "))
  }

  paste(lines, collapse = "\n")
}

.ark_view_numeric_distribution_lines <- function(column, bins = 10L, width = 24L) {
  values <- suppressWarnings(as.numeric(column))
  values <- values[is.finite(values)]
  if (!length(values)) {
    return("  no finite values")
  }

  if (length(unique(values)) == 1L) {
    return(sprintf(
      "  %s | %s %d",
      .ark_view_stringify_value(values[[1L]], max_chars = 14L),
      paste(rep("#", width), collapse = ""),
      length(values)
    ))
  }

  histogram <- hist(values, breaks = "FD", plot = FALSE, include.lowest = TRUE, right = FALSE)
  if (length(histogram$counts) > bins) {
    histogram <- hist(values, breaks = bins, plot = FALSE, include.lowest = TRUE, right = FALSE)
  }

  max_count <- max(histogram$counts)
  vapply(seq_along(histogram$counts), function(index) {
    count <- histogram$counts[[index]]
    bar_width <- if (count > 0L && max_count > 0L) {
      max(1L, as.integer(round((count / max_count) * width)))
    } else {
      0L
    }
    sprintf(
      "  %s-%s | %s %d",
      .ark_view_stringify_value(histogram$breaks[[index]], max_chars = 8L),
      .ark_view_stringify_value(histogram$breaks[[index + 1L]], max_chars = 8L),
      paste(rep("#", bar_width), collapse = ""),
      count
    )
  }, character(1))
}

.ark_view_profile_payload <- function(session, session_id, column_index) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    data <- .ark_view_current_data(view)
    column_index <- suppressWarnings(as.integer(column_index))
    if (is.na(column_index) || column_index < 1L || column_index > ncol(data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid column_index", "ipc_view_profile")
    }

    column <- data[[column_index]]
    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      column_index = as.integer(column_index),
      text = .ark_view_profile_text(column, names(data)[[column_index]])
    ))
  })
}

.ark_view_code_payload <- function(session, session_id) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    lines <- c(sprintf(".ark_view <- %s", view$expr))

    filters <- view$filters %||% list()
    for (name in names(filters)) {
      index <- suppressWarnings(as.integer(name))
      if (is.na(index) || index < 1L || index > ncol(view$data)) {
        next
      }
      column_name <- names(view$data)[[index]]
      query <- filters[[name]]
      lines <- c(
        lines,
        sprintf(
          ".ark_view <- .ark_view[grepl(%s, as.character(.ark_view%s), fixed = TRUE, ignore.case = TRUE), , drop = FALSE]",
          .ark_view_escape_code_string(query),
          .ark_view_column_accessor(column_name)
        )
      )
    }

    direction <- as.character(view$sort$direction %||% "")
    column_index <- suppressWarnings(as.integer(view$sort$column_index %||% 0L))
    if (direction %in% c("asc", "desc") && column_index >= 1L && column_index <= ncol(view$data)) {
      column_name <- names(view$data)[[column_index]]
      lines <- c(
        lines,
        sprintf(
          ".ark_view <- .ark_view[order(.ark_view%s, decreasing = %s, na.last = TRUE), , drop = FALSE]",
          .ark_view_column_accessor(column_name),
          if (identical(direction, "desc")) "TRUE" else "FALSE"
        )
      )
    }

    lines <- c(lines, ".ark_view")
    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      language = "r",
      code = paste(lines, collapse = "\n")
    ))
  })
}

.ark_view_export_payload <- function(session, session_id, format = "tsv") {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    data <- .ark_view_current_data(view)
    format <- tolower(as.character(format %||% "tsv"))
    sep <- if (identical(format, "csv")) "," else "\t"
    quote <- identical(format, "csv")
    out <- paste(capture.output(
      utils::write.table(data, sep = sep, row.names = FALSE, col.names = TRUE, quote = quote)
    ), collapse = "\n")

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      format = format,
      text = out
    ))
  })
}

.ark_view_cell_payload <- function(session, session_id, row_index, column_index) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    data <- .ark_view_current_data(view)
    row_index <- suppressWarnings(as.integer(row_index))
    column_index <- suppressWarnings(as.integer(column_index))
    if (is.na(row_index) || row_index < 1L || row_index > nrow(data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid row_index", "ipc_view_cell")
    }
    if (is.na(column_index) || column_index < 1L || column_index > ncol(data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid column_index", "ipc_view_cell")
    }

    value <- data[[column_index]][[row_index]]
    text <- paste(capture.output(str(value, give.attr = FALSE, vec.len = 5L)), collapse = "\n")
    if (!nzchar(trimws(text))) {
      text <- .ark_view_stringify_value(value, max_chars = 400L)
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      row_index = as.integer(row_index),
      column_index = as.integer(column_index),
      text = text
    ))
  })
}

.ark_view_close_payload <- function(session, session_id) {
  .ark_view_safe(session, {
    if (is.character(session_id) && length(session_id) == 1L && nzchar(session_id)) {
      rm(list = session_id, envir = .ark_ipc_state$views, inherits = FALSE)
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      closed = TRUE
    ))
  })
}
