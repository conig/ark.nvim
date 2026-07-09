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

.ark_view_default_row_names <- function(row_names) {
  if (!is.character(row_names)) {
    return(TRUE)
  }

  identical(row_names, as.character(seq_along(row_names)))
}

.ark_view_promote_row_names <- function(data, column_name = "name") {
  row_names <- row.names(data)
  if (.ark_view_default_row_names(row_names)) {
    return(data)
  }

  name <- column_name
  existing <- names(data)
  while (name %in% existing) {
    name <- paste0(name, "_")
  }

  out <- cbind(
    setNames(data.frame(row_names, stringsAsFactors = FALSE, check.names = FALSE), name),
    data
  )
  row.names(out) <- NULL
  out
}

.ark_view_plain_list <- function(x) {
  is.list(x) && !is.data.frame(x) && !inherits(x, "table")
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

  if (.ark_view_plain_list(x)) {
    .ark_view_fail(
      "E_IPC_VIEW_TYPE",
      sprintf("unsupported table object for ArkView: %s", paste(class(x), collapse = "/")),
      "ipc_view_open"
    )
  }

  adapter <- tryCatch(
    as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE),
    error = function(e) NULL
  )
  if (is.data.frame(adapter) && ncol(adapter) > 0L) {
    names(adapter) <- vapply(seq_along(adapter), function(index) {
      name <- names(adapter)[[index]] %||% ""
      if (nzchar(name)) {
        return(name)
      }
      if (ncol(adapter) == 1L) {
        return("value")
      }
      paste0("V", index)
    }, character(1))
    return(.ark_view_promote_row_names(adapter))
  }

  if (.ark_view_is_rectangular(x)) {
    out <- as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE)
    column_names <- colnames(x)
    if (!is.character(column_names) || length(column_names) != ncol(out)) {
      column_names <- paste0("V", seq_len(ncol(out)))
    }
    names(out) <- column_names
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
    kind = "table",
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

.ark_object_should_open_tree <- function(object) {
  .ark_view_plain_list(object)
}

.ark_object_node_path <- function(node_id) {
  node_id <- as.character(node_id %||% "")
  if (!nzchar(node_id)) {
    return(integer())
  }

  parts <- strsplit(node_id, "/", fixed = TRUE)[[1L]]
  path <- suppressWarnings(as.integer(parts))
  if (any(is.na(path)) || any(path < 1L)) {
    .ark_view_fail("E_IPC_REQUEST", "invalid object node id", "ipc_object_node")
  }
  path
}

.ark_object_node_id <- function(path) {
  path <- suppressWarnings(as.integer(path))
  path <- path[!is.na(path) & path >= 1L]
  paste(path, collapse = "/")
}

.ark_object_expandable <- function(value) {
  .ark_view_plain_list(value) && length(value) > 0L
}

.ark_object_table_viewable <- function(value) {
  if (.ark_view_plain_list(value)) {
    return(FALSE)
  }

  is.data.frame(tryCatch(.ark_view_as_table(value), error = function(e) NULL))
}

.ark_object_resolve_path <- function(object, path) {
  value <- object
  for (index in path) {
    if (!.ark_object_expandable(value) || index > length(value)) {
      .ark_view_fail("E_IPC_REQUEST", "object node not found", "ipc_object_node")
    }
    value <- value[[index]]
  }
  value
}

.ark_object_child_name <- function(parent, index) {
  item_names <- names(parent)
  if (is.character(item_names) && index <= length(item_names) && nzchar(item_names[[index]] %||% "")) {
    return(item_names[[index]])
  }
  paste0("[[", index, "]]")
}

.ark_object_path_expr <- function(root_expr, root_object, path) {
  expr <- as.character(root_expr %||% "")
  value <- root_object
  for (index in path) {
    name <- .ark_object_child_name(value, index)
    if (!startsWith(name, "[[") && .is_syntactic_name(name)) {
      expr <- paste0(expr, "$", name)
    } else if (!startsWith(name, "[[")) {
      expr <- paste0(expr, "[[", .ark_view_escape_code_string(name), "]]")
    } else {
      expr <- paste0(expr, "[[", index, "]]")
    }
    value <- value[[index]]
  }
  expr
}

.ark_object_class_label <- function(value) {
  class <- paste(class(value), collapse = "/")
  if (!nzchar(class)) {
    class <- typeof(value)
  }
  class
}

.ark_object_summary <- function(value) {
  dims <- dim(value)
  if (!is.null(dims)) {
    return(paste0(paste(dims, collapse = " x "), " ", .ark_object_class_label(value)))
  }

  if (is.null(value)) {
    return("NULL")
  }

  if (length(value) == 1L && is.atomic(value)) {
    return(.ark_view_display_value(value, max_chars = 60L))
  }

  paste0("length ", length(value))
}

.ark_object_table_preview_text <- function(value, max_rows = 6L, max_columns = 6L) {
  data <- .ark_view_as_table(value)
  schema <- .ark_view_schema(data)
  rows <- min(nrow(data), max_rows)
  columns <- min(ncol(data), max_columns)
  lines <- c(sprintf("# %s: %d x %d", .ark_object_class_label(value), nrow(data), ncol(data)))
  if (columns < 1L) {
    return(paste(lines, collapse = "\n"))
  }

  names_line <- vapply(seq_len(columns), function(index) {
    names(data)[[index]] %||% paste0("V", index)
  }, character(1))
  class_line <- vapply(seq_len(columns), function(index) {
    paste0("<", schema[[index]]$class %||% schema[[index]]$type %||% "unknown", ">")
  }, character(1))
  values <- lapply(seq_len(columns), function(column_index) {
    if (rows < 1L) {
      return(character())
    }
    vapply(data[[column_index]][seq_len(rows)], .ark_view_display_value, character(1), USE.NAMES = FALSE)
  })

  widths <- vapply(seq_len(columns), function(index) {
    max(
      nchar(names_line[[index]], type = "width"),
      nchar(class_line[[index]], type = "width"),
      if (rows > 0L) max(nchar(values[[index]], type = "width")) else 0L,
      1L
    )
  }, integer(1))
  pad <- function(text, width) {
    paste0(text, paste(rep(" ", max(0L, width - nchar(text, type = "width"))), collapse = ""))
  }
  join <- function(parts) paste(parts, collapse = "  ")

  lines <- c(
    lines,
    join(vapply(seq_len(columns), function(index) pad(names_line[[index]], widths[[index]]), character(1))),
    join(vapply(seq_len(columns), function(index) pad(class_line[[index]], widths[[index]]), character(1)))
  )
  if (rows > 0L) {
    for (row in seq_len(rows)) {
      lines <- c(lines, join(vapply(seq_len(columns), function(index) {
        pad(values[[index]][[row]], widths[[index]])
      }, character(1))))
    }
  }
  if (nrow(data) > rows || ncol(data) > columns) {
    lines <- c(lines, sprintf("# ... with %d more rows and %d more columns", nrow(data) - rows, ncol(data) - columns))
  }

  paste(lines, collapse = "\n")
}

.ark_object_detail_text <- function(value) {
  if (.ark_object_table_viewable(value)) {
    return(.ark_object_table_preview_text(value))
  }

  text <- paste(utils::capture.output(str(value, give.attr = FALSE, max.level = 2L, vec.len = 6L)), collapse = "\n")
  if (!nzchar(trimws(text))) {
    text <- .ark_view_display_value(value, max_chars = 400L)
  }
  text
}

.ark_object_node_info <- function(view, path, value = NULL) {
  if (is.null(value) && length(path) == 0L) {
    value <- view$object
  } else if (is.null(value)) {
    value <- .ark_object_resolve_path(view$object, path)
  }

  parent_path <- if (length(path) > 0L) path[-length(path)] else integer()
  parent <- if (length(path) > 0L) .ark_object_resolve_path(view$object, parent_path) else NULL
  name <- if (length(path) > 0L) .ark_object_child_name(parent, path[[length(path)]]) else view$title
  list(
    node_id = .ark_object_node_id(path),
    parent_id = .ark_object_node_id(parent_path),
    name = as.character(name %||% ""),
    path = .ark_object_path_expr(view$expr, view$object, path),
    depth = as.integer(length(path)),
    type = typeof(value),
    class = .ark_object_class_label(value),
    length = as.integer(length(value)),
    summary = .ark_object_summary(value),
    expandable = .ark_object_expandable(value),
    viewable_table = .ark_object_table_viewable(value),
    child_count = if (.ark_object_expandable(value)) as.integer(length(value)) else 0L
  )
}

.ark_object_state_payload_data <- function(view) {
  root <- .ark_object_node_info(view, integer(), view$object)
  list(
    kind = "tree",
    session_id = view$session_id,
    title = view$title,
    source_label = view$expr,
    root = root,
    total_children = as.integer(root$child_count %||% 0L)
  )
}

.ark_object_open_object_payload <- function(session, object, expr, title = NULL) {
  session_id <- .ark_view_generate_id()
  view <- list(
    kind = "tree",
    session_id = session_id,
    expr = expr,
    title = title %||% .ark_view_normalize_title(expr),
    object = object
  )
  assign(session_id, view, envir = .ark_ipc_state$views)

  .emit_json(utils::modifyList(
    list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session
    ),
    .ark_object_state_payload_data(view)
  ))
}

.ark_object_children_payload <- function(session, session_id, node_id = "", offset = 0L, limit = 0L) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    path <- .ark_object_node_path(node_id)
    value <- .ark_object_resolve_path(view$object, path)
    if (!.ark_object_expandable(value)) {
      children <- list()
      total <- 0L
    } else {
      total <- length(value)
      offset <- suppressWarnings(as.integer(offset))
      limit <- suppressWarnings(as.integer(limit))
      if (is.na(offset) || offset < 0L) offset <- 0L
      if (is.na(limit) || limit < 0L) limit <- 0L
      start <- offset + 1L
      end <- if (identical(limit, 0L)) total else min(total, offset + limit)
      if (start > total) {
        indices <- integer()
      } else {
        indices <- seq.int(start, end)
      }
      children <- lapply(indices, function(index) {
        .ark_object_node_info(view, c(path, index), value[[index]])
      })
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      node_id = as.character(node_id %||% ""),
      offset = as.integer(offset %||% 0L),
      limit = as.integer(limit %||% 0L),
      total_children = as.integer(total),
      children = children
    ))
  })
}

.ark_object_detail_payload <- function(session, session_id, node_id = "") {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    path <- .ark_object_node_path(node_id)
    value <- .ark_object_resolve_path(view$object, path)
    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      node_id = as.character(node_id %||% ""),
      info = .ark_object_node_info(view, path, value),
      text = .ark_object_detail_text(value)
    ))
  })
}

.ark_object_table_payload <- function(session, session_id, node_id = "") {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    path <- .ark_object_node_path(node_id)
    value <- .ark_object_resolve_path(view$object, path)
    if (!.ark_object_table_viewable(value)) {
      .ark_view_fail("E_IPC_VIEW_TYPE", "object node is not table-viewable", "ipc_object_table")
    }

    info <- .ark_object_node_info(view, path, value)
    .ark_view_open_object_payload(session, value, info$path, title = info$name)
  })
}

.ark_object_search_payload <- function(session, session_id, query = "", max_nodes = 1000L, max_results = 100L) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    query <- tolower(trimws(as.character(query %||% "")))
    max_nodes <- suppressWarnings(as.integer(max_nodes))
    max_results <- suppressWarnings(as.integer(max_results))
    if (is.na(max_nodes) || max_nodes < 1L) max_nodes <- 1000L
    if (is.na(max_results) || max_results < 1L) max_results <- 100L

    visited <- 0L
    matches <- list()
    add_match <- function(info) {
      if (length(matches) >= max_results) {
        return()
      }
      haystack <- tolower(paste(info$name, info$type, info$class, info$summary, sep = " "))
      if (!nzchar(query) || grepl(query, haystack, fixed = TRUE)) {
        matches[[length(matches) + 1L]] <<- info
      }
    }
    walk <- function(value, path) {
      if (visited >= max_nodes || length(matches) >= max_results) {
        return()
      }
      visited <<- visited + 1L
      if (length(path) > 0L) {
        add_match(.ark_object_node_info(view, path, value))
      }
      if (!.ark_object_expandable(value)) {
        return()
      }
      for (index in seq_along(value)) {
        walk(value[[index]], c(path, index))
        if (visited >= max_nodes || length(matches) >= max_results) {
          return()
        }
      }
    }

    walk(view$object, integer())
    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      query = query,
      visited = as.integer(visited),
      matches = matches
    ))
  })
}

.ark_view_open_object_payload <- function(session, object, expr, title = NULL) {
  .ark_view_safe(session, {
    if (.ark_object_should_open_tree(object)) {
      return(.ark_object_open_object_payload(session, object, expr, title = title))
    }

    data <- .ark_view_as_table(object)
    session_id <- .ark_view_generate_id()
    view <- list(
      kind = "table",
      session_id = session_id,
      expr = expr,
      title = title %||% .ark_view_normalize_title(expr),
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

.ark_view_open_payload <- function(session, expr, options = list()) {
  .ark_view_safe(session, {
    env <- .ark_resolve_eval_env(expr, options)
    object <- eval(parse(text = expr, keep.source = FALSE), envir = env)
    .ark_view_open_object_payload(session, object, expr)
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

.ark_view_page_payload <- function(session, session_id, offset = 0L, limit = 0L, columns = integer()) {
  .ark_view_safe(session, {
    view <- .ark_view_require_session_id(session, session_id)
    data <- .ark_view_current_data(view)
    offset <- suppressWarnings(as.integer(offset))
    limit <- suppressWarnings(as.integer(limit))
    if (is.na(offset) || offset < 0L) offset <- 0L
    if (is.na(limit) || limit < 0L) limit <- 0L
    columns <- suppressWarnings(as.integer(unlist(columns, use.names = FALSE)))
    columns <- unique(columns[!is.na(columns) & columns >= 1L & columns <= ncol(data)])
    projected <- length(columns) > 0L

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

    page_column_indices <- if (projected) columns else seq_len(ncol(page))
    displayed_columns <- lapply(page_column_indices, function(column_index) {
      vapply(page[[column_index]], .ark_view_display_value, character(1), USE.NAMES = FALSE)
    })
    page_rows <- vector("list", nrow(page))
    column_names <- if (projected) as.character(columns) else NULL
    for (index in seq_len(nrow(page))) {
      values <- lapply(displayed_columns, `[[`, index)
      if (projected) {
        names(values) <- column_names
      }
      page_rows[[index]] <- values
    }

    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      session_id = session_id,
      offset = as.integer(offset),
      limit = as.integer(limit),
      columns = if (projected) I(as.integer(columns)) else NULL,
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
