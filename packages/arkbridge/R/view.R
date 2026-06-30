.ark_view_error_payload <- function(session, code, message, stage) {
  .emit_json(.new_error_payload(code, message, stage, session))
}

.ark_view_generate_id <- function() {
  paste0(
    "view-",
    as.integer(Sys.getpid()),
    "-",
    sprintf("%.0f", as.numeric(Sys.time()) * 1000),
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

.ark_view_fixed_search <- function(query, values) {
  query <- tolower(as.character(query %||% ""))
  values <- tolower(as.character(values))
  grepl(query, values, fixed = TRUE)
}

.ark_view_value_label <- function(value, max_chars = 80L) {
  if (is.null(value) || length(value) == 0L) {
    return("")
  }

  if (is.list(value) && !is.object(value)) {
    value <- value[[1L]]
  }

  if (length(value) == 1L && is.atomic(value) && is.na(value)) {
    return("<NA>")
  }

  .ark_view_display_value(value, max_chars = max_chars)
}

.ark_view_value_key <- function(value) {
  if (is.null(value) || length(value) == 0L) {
    return("null:")
  }

  if (is.list(value) && !is.object(value)) {
    value <- value[[1L]]
  }

  class_key <- paste(class(value), collapse = "/")
  if (length(value) == 1L && is.atomic(value) && is.na(value)) {
    return(paste0(class_key, ":<NA>"))
  }

  value_key <- tryCatch(
    paste(encodeString(as.character(value), quote = "\""), collapse = "\r"),
    error = function(e) paste(utils::capture.output(str(value, give.attr = FALSE, vec.len = 5L)), collapse = " ")
  )
  paste0(class_key, ":", value_key)
}

.ark_view_filter_mode <- function(filter) {
  if (is.list(filter)) {
    mode <- as.character(filter$mode %||% "contains")
    if (nzchar(mode)) {
      return(mode)
    }
  }
  "contains"
}

.ark_view_filter_query <- function(filter) {
  if (is.list(filter)) {
    return(as.character(filter$query %||% ""))
  }
  as.character(filter %||% "")
}

.ark_view_filter_threshold <- function(filter) {
  if (!is.list(filter)) {
    return(NA_real_)
  }
  suppressWarnings(as.numeric(filter$threshold %||% NA_real_))
}

.ark_view_filter_value_key <- function(filter) {
  if (!is.list(filter)) {
    return("")
  }
  as.character(filter$value_key %||% "")
}

.ark_view_numeric_filter_column <- function(column) {
  is.numeric(column) || is.integer(column)
}

.ark_view_parse_filter <- function(column, query, mode = "contains", value_key = "", label = "") {
  query <- as.character(query %||% "")
  mode <- as.character(mode %||% "contains")
  value_key <- as.character(value_key %||% "")
  label <- as.character(label %||% "")
  if (!nzchar(mode) || identical(mode, "auto")) {
    mode <- "contains"
  }

  if (identical(mode, "contains")) {
    if (!nzchar(query)) {
      return(NULL)
    }

    trimmed <- trimws(query)
    comparator <- regexec("^([<>])\\s*(.+)$", trimmed)
    parts <- regmatches(trimmed, comparator)[[1L]]
    if (length(parts) == 3L) {
      threshold <- suppressWarnings(as.numeric(parts[[3L]]))
      if (is.na(threshold) || !is.finite(threshold)) {
        .ark_view_fail("E_IPC_REQUEST", "invalid numeric comparison filter", "ipc_view_filter")
      }
      if (!.ark_view_numeric_filter_column(column)) {
        .ark_view_fail("E_IPC_REQUEST", "numeric comparison filters require a numeric column", "ipc_view_filter")
      }

      return(list(
        mode = if (identical(parts[[2L]], "<")) "lt" else "gt",
        query = paste(parts[[2L]], format(threshold, trim = TRUE, scientific = FALSE)),
        threshold = threshold
      ))
    }

    return(list(mode = "contains", query = query))
  }

  if (identical(mode, "exact")) {
    if (!nzchar(value_key)) {
      .ark_view_fail("E_IPC_REQUEST", "missing exact filter value", "ipc_view_filter")
    }
    if (!nzchar(label)) {
      label <- query
    }
    return(list(mode = "exact", query = label, value_key = value_key))
  }

  if (mode %in% c("lt", "gt")) {
    threshold <- suppressWarnings(as.numeric(query))
    if (is.na(threshold) || !is.finite(threshold)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid numeric comparison filter", "ipc_view_filter")
    }
    if (!.ark_view_numeric_filter_column(column)) {
      .ark_view_fail("E_IPC_REQUEST", "numeric comparison filters require a numeric column", "ipc_view_filter")
    }
    return(list(
      mode = mode,
      query = paste(if (identical(mode, "lt")) "<" else ">", format(threshold, trim = TRUE, scientific = FALSE)),
      threshold = threshold
    ))
  }

  .ark_view_fail("E_IPC_REQUEST", "invalid filter mode", "ipc_view_filter")
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

.ark_view_truncate_text <- function(txt, max_chars = 80L) {
  max_chars <- suppressWarnings(as.integer(max_chars))
  if (is.na(max_chars) || max_chars < 1L) {
    max_chars <- 80L
  }

  txt <- as.character(txt %||% "")
  if (nchar(txt, type = "bytes") <= max_chars) {
    return(txt)
  }

  if (max_chars <= 3L) {
    return(substr(txt, 1L, max_chars))
  }

  paste0(substr(txt, 1L, max_chars - 3L), "...")
}

.ark_view_visible_space <- function(count) {
  paste(rep("\\x20", count), collapse = "")
}

.ark_view_visible_character <- function(ch) {
  if (identical(ch, "\\")) {
    return("\\\\")
  }
  if (identical(ch, "\r")) {
    return("\\r")
  }
  if (identical(ch, "\n")) {
    return("\\n")
  }
  if (identical(ch, "\t")) {
    return("\\t")
  }
  ch
}

.ark_view_display_character_value <- function(value, max_chars = 80L) {
  value <- as.character(value)[[1L]]
  if (is.na(value)) {
    return("NA")
  }
  if (!nzchar(value)) {
    return("\"\"")
  }

  chars <- strsplit(value, "", fixed = TRUE, useBytes = FALSE)[[1L]]
  if (!length(chars)) {
    return("\"\"")
  }

  runs <- rle(chars == " ")
  out <- character()
  position <- 1L
  for (index in seq_along(runs$lengths)) {
    run_length <- runs$lengths[[index]]
    run_end <- position + run_length - 1L
    is_space <- runs$values[[index]]

    if (is_space) {
      at_boundary <- position == 1L || run_end == length(chars)
      if (at_boundary || run_length > 1L) {
        out <- c(out, .ark_view_visible_space(run_length))
      } else {
        out <- c(out, " ")
      }
    } else {
      out <- c(out, vapply(chars[position:run_end], .ark_view_visible_character, character(1)))
    }

    position <- run_end + 1L
  }

  .ark_view_truncate_text(paste(out, collapse = ""), max_chars)
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

  .ark_view_truncate_text(txt, max_chars)
}

.ark_view_display_value <- function(value, max_chars = 80L) {
  if (is.null(value) || length(value) == 0L) {
    return("")
  }

  if (is.list(value) && !is.object(value)) {
    value <- value[[1L]]
  }

  if ((is.character(value) || is.factor(value)) && length(value) == 1L) {
    return(.ark_view_display_character_value(value, max_chars))
  }

  .ark_view_stringify_value(value, max_chars)
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

.ark_view_apply_filters <- function(data, filters, exclude_column = NULL) {
  if (!length(filters)) {
    return(data)
  }

  keep <- rep(TRUE, nrow(data))
  for (name in names(filters)) {
    query <- filters[[name]]
    if (is.null(query) || (is.character(query) && !nzchar(query))) {
      next
    }

    index <- suppressWarnings(as.integer(name))
    if (is.na(index) || index < 1L || index > ncol(data)) {
      next
    }
    if (!is.null(exclude_column) && identical(index, as.integer(exclude_column))) {
      next
    }

    mode <- .ark_view_filter_mode(query)
    if (identical(mode, "contains")) {
      filter_query <- .ark_view_filter_query(query)
      if (!nzchar(filter_query)) {
        next
      }
      values <- vapply(data[[index]], .ark_view_stringify_value, character(1))
      matches <- .ark_view_fixed_search(filter_query, values)
    } else if (identical(mode, "exact")) {
      value_key <- .ark_view_filter_value_key(query)
      if (!nzchar(value_key)) {
        next
      }
      values <- vapply(data[[index]], .ark_view_value_key, character(1))
      matches <- identical(value_key, "") | values == value_key
    } else if (mode %in% c("lt", "gt")) {
      threshold <- .ark_view_filter_threshold(query)
      if (is.na(threshold) || !is.finite(threshold)) {
        next
      }
      values <- suppressWarnings(as.numeric(data[[index]]))
      matches <- if (identical(mode, "lt")) values < threshold else values > threshold
    } else {
      next
    }
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

.ark_view_current_data <- function(view, exclude_filter_column = NULL) {
  data <- view$data
  data <- .ark_view_apply_filters(data, view$filters %||% list(), exclude_column = exclude_filter_column)
  .ark_view_apply_sort(data, view$sort %||% list())
}

.ark_view_state_payload_data <- function(view) {
  data <- .ark_view_current_data(view)
  filters <- view$filters %||% list()
  filter_list <- lapply(names(filters), function(name) {
    filter <- filters[[name]]
    list(
      column_index = suppressWarnings(as.integer(name)),
      query = .ark_view_filter_query(filter),
      mode = .ark_view_filter_mode(filter)
    )
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

.ark_view_page_payload <- function(session, session_id, offset = 0L, limit = 0L) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    data <- .ark_view_current_data(view)
    offset <- suppressWarnings(as.integer(offset))
    limit <- suppressWarnings(as.integer(limit))
    if (is.na(offset) || offset < 0L) offset <- 0L
    if (is.na(limit) || limit < 0L) limit <- 0L

    total_rows <- nrow(data)
    if (offset >= total_rows) {
      page <- data[0, , drop = FALSE]
      row_numbers <- integer()
    } else {
      end <- if (identical(limit, 0L)) total_rows else min(total_rows, offset + limit)
      rows <- seq.int(offset + 1L, end)
      page <- data[rows, , drop = FALSE]
      row_numbers <- rows
    }

    page_rows <- lapply(seq_len(nrow(page)), function(index) {
      row <- page[index, , drop = FALSE]
      unname(lapply(seq_len(ncol(row)), function(column_index) {
        .ark_view_display_value(row[[column_index]][[1L]])
      }))
    })

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      offset = as.integer(offset),
      limit = as.integer(limit),
      total_rows = as.integer(total_rows),
      row_numbers = I(as.integer(row_numbers)),
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

.ark_view_filter_payload <- function(session, session_id, column_index, query, mode = "contains", value_key = "", label = "") {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    column_index <- suppressWarnings(as.integer(column_index))
    query <- as.character(query %||% "")
    if (is.na(column_index) || column_index < 1L || column_index > ncol(view$data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid column_index", "ipc_view_filter")
    }

    filters <- view$filters %||% list()
    key <- as.character(column_index)
    filter <- .ark_view_parse_filter(view$data[[column_index]], query, mode, value_key, label)
    if (!is.null(filter)) {
      filters[[key]] <- filter
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

.ark_view_values_payload <- function(session, session_id, column_index) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    column_index <- suppressWarnings(as.integer(column_index))
    if (is.na(column_index) || column_index < 1L || column_index > ncol(view$data)) {
      .ark_view_fail("E_IPC_REQUEST", "invalid column_index", "ipc_view_values")
    }

    data <- .ark_view_current_data(view, exclude_filter_column = column_index)
    column <- data[[column_index]]
    if (!length(column)) {
      values <- list()
    } else {
      keys <- vapply(column, .ark_view_value_key, character(1))
      labels <- vapply(column, .ark_view_value_label, character(1))
      counts <- sort(table(keys, useNA = "no"), decreasing = TRUE)
      values <- lapply(names(counts), function(key) {
        first <- match(key, keys)
        list(
          label = labels[[first]],
          value_key = key,
          count = as.integer(counts[[key]])
        )
      })
      values <- values[order(
        -vapply(values, function(item) item$count %||% 0L, integer(1)),
        vapply(values, function(item) item$label %||% "", character(1))
      )]
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      column_index = as.integer(column_index),
      total_values = as.integer(length(values)),
      values = values
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
      .ark_view_fixed_search(query, item$name) ||
        .ark_view_fixed_search(query, item$class) ||
        .ark_view_fixed_search(query, item$type)
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
    .ark_view_display_value(value, max_chars = 40L)
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
      filter <- filters[[name]]
      mode <- .ark_view_filter_mode(filter)
      query <- .ark_view_filter_query(filter)
      if (identical(mode, "contains")) {
        lines <- c(
          lines,
          sprintf(
            ".ark_view <- .ark_view[grepl(tolower(%s), tolower(as.character(.ark_view%s)), fixed = TRUE), , drop = FALSE]",
            .ark_view_escape_code_string(query),
            .ark_view_column_accessor(column_name)
          )
        )
      } else if (mode %in% c("lt", "gt")) {
        threshold <- .ark_view_filter_threshold(filter)
        operator <- if (identical(mode, "lt")) "<" else ">"
        lines <- c(
          lines,
          sprintf(".ark_filter_values <- suppressWarnings(as.numeric(.ark_view%s))", .ark_view_column_accessor(column_name)),
          sprintf(
            ".ark_view <- .ark_view[!is.na(.ark_filter_values) & .ark_filter_values %s %s, , drop = FALSE]",
            operator,
            format(threshold, trim = TRUE, scientific = FALSE)
          ),
          "rm(.ark_filter_values)"
        )
      } else if (identical(mode, "exact")) {
        lines <- c(
          lines,
          sprintf(
            ".ark_view <- .ark_view[vapply(.ark_view%s, function(.ark_value) { if (length(.ark_value) == 1L && is.atomic(.ark_value) && is.na(.ark_value)) '<NA>' else paste(format(.ark_value, trim = TRUE, justify = 'none'), collapse = ' ') }, character(1)) == %s, , drop = FALSE]",
            .ark_view_column_accessor(column_name),
            .ark_view_escape_code_string(query)
          )
        )
      }
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
