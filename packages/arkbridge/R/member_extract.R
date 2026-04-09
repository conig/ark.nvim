.member_names_r <- function(obj, accessor) {
  if (identical(accessor, "@") && isS4(obj)) {
    return(methods::slotNames(obj))
  }

  if (identical(accessor, "arg") && is.function(obj)) {
    fml <- formals(obj)
    if (is.null(fml)) return(character(0))
    nms <- names(fml)
    if (is.null(nms)) return(character(0))
    return(as.character(nms))
  }

  if (identical(accessor, "$") && inherits(obj, "data.table")) {
    nm <- colnames(obj)
    if (is.null(nm)) return(character(0))
    return(as.character(nm))
  }

  if (is.environment(obj)) {
    return(ls(envir = obj, all.names = TRUE))
  }

  nm <- names(obj)
  if (is.null(nm)) character(0) else as.character(nm)
}

.member_names_c <- function(obj, accessor) {
  .Call("C_ark_member_names", obj, accessor)
}

.member_names <- function(obj, accessor, options = list()) {
  if (identical(accessor, "arg") && is.function(obj)) {
    return(.member_names_r(obj, accessor))
  }

  prefer_c <- isTRUE(options$prefer_c %||% TRUE)
  if (prefer_c) {
    res <- tryCatch(.member_names_c(obj, accessor), error = function(e) NULL)
    if (!is.null(res)) {
      res <- as.character(res)
      if (length(res) > 0L) {
        return(res)
      }
    }
  }

  .member_names_r(obj, accessor)
}

.member_value <- function(obj, accessor, name) {
  if (identical(accessor, "@") && isS4(obj)) {
    return(methods::slot(obj, name))
  }

  if (identical(accessor, "arg") && is.function(obj)) {
    fml <- formals(obj)
    if (is.null(fml)) {
      return(NULL)
    }
    fml_list <- as.list(fml)
    if (is.null(fml_list) || !name %in% names(fml_list)) {
      return(NULL)
    }
    return(fml_list[[name]])
  }

  if (is.environment(obj)) {
    return(get(name, envir = obj, inherits = FALSE))
  }

  obj[[name]]
}

.member_size <- function(x) {
  if (is.null(x)) return(0L)
  if (is.atomic(x)) return(length(x))
  if (is.list(x)) return(length(x))
  if (is.environment(x)) return(length(ls(envir = x, all.names = TRUE)))
  if (isS4(x)) return(length(methods::slotNames(x)))
  length(x)
}

.member_summary <- function(x, max_chars = 80L) {
  if (is.symbol(x) && identical(as.character(x), "")) {
    return("<required>")
  }

  out <- paste(utils::capture.output(utils::str(x, give.attr = FALSE, vec.len = 3L)), collapse = " ")
  if (nchar(out, type = "bytes") > max_chars) {
    paste0(substr(out, 1L, max_chars - 3L), "...")
  } else {
    out
  }
}

.member_insert_text <- function(name, accessor) {
  if (identical(accessor, "arg")) {
    if (.is_syntactic_name(name)) {
      return(paste0(name, " = "))
    }
    escaped <- gsub("`", "``", name, fixed = TRUE)
    return(sprintf("`%s` = ", escaped))
  }

  if (identical(accessor, "@")) {
    if (.is_syntactic_name(name)) {
      return(paste0("@", name))
    }
    return(sprintf("@`%s`", name))
  }

  if (.is_syntactic_name(name)) {
    return(paste0("$", name))
  }

  sprintf('[["%s"]]', name)
}

.member_completion_text <- function(name, accessor) {
  if (identical(accessor, "arg")) {
    if (.is_syntactic_name(name)) {
      return(paste0(name, " = "))
    }
    escaped <- gsub("`", "``", name, fixed = TRUE)
    return(sprintf("`%s` = ", escaped))
  }

  if (identical(accessor, "@")) {
    return(paste0("@", name))
  }

  if (.is_syntactic_name(name)) {
    return(paste0("$", name))
  }

  sprintf('[["%s"]]', name)
}

.member_top_values <- function(x, max_values = 5L) {
  if (length(x) == 0L) return(list())
  if (is.factor(x)) x <- as.character(x)
  if (!is.atomic(x)) return(list())

  vals <- x[!is.na(x)]
  if (length(vals) == 0L) return(list())

  tbl <- sort(table(vals), decreasing = TRUE)
  n <- min(length(tbl), as.integer(max_values))
  if (n <= 0L) return(list())

  out <- vector("list", n)
  for (i in seq_len(n)) {
    out[[i]] <- list(
      value = as.character(names(tbl)[i]),
      n = unname(as.integer(tbl[[i]]))
    )
  }
  out
}

.member_density_defaults <- function(options = list()) {
  list(
    bins = as.integer(options$density_bins %||% 24L),
    max_sample = as.integer(options$density_max_sample %||% 4000L),
    hard_limit = as.integer(options$density_hard_limit %||% 1000000L),
    min_n = as.integer(options$density_min_n %||% 2L),
    width = as.integer(options$density_width %||% 35L),
    height = as.integer(options$density_height %||% 15L)
  )
}

.new_density_result <- function(kind, bins_used, n_used, sampled, skipped_reason = NULL, density_plot = NULL) {
  list(
    density_plot = density_plot,
    density_meta = list(
      kind = as.character(kind),
      bins_used = as.integer(bins_used),
      n_used = as.integer(n_used),
      sampled = isTRUE(sampled),
      skipped_reason = if (is.null(skipped_reason)) NULL else as.character(skipped_reason)
    )
  )
}

.member_density_fallback <- function(x_used, bins) {
  x_range <- range(x_used, na.rm = TRUE, finite = TRUE)
  if (length(x_range) != 2L || !all(is.finite(x_range))) {
    return("")
  }

  if (identical(x_range[[1]], x_range[[2]])) {
    counts <- rep.int(0L, bins)
    counts[ceiling(bins / 2)] <- length(x_used)
  } else {
    h <- hist(
      x_used,
      breaks = seq(x_range[[1]], x_range[[2]], length.out = bins + 1L),
      plot = FALSE,
      include.lowest = TRUE,
      right = TRUE
    )
    counts <- as.integer(h$counts)
  }

  max_count <- max(counts)
  if (!is.finite(max_count) || max_count <= 0L) {
    return("")
  }

  charset <- strsplit(" .:-=+*#%@", split = "", fixed = TRUE)[[1]]
  idx <- floor((counts / max_count) * (length(charset) - 1L)) + 1L
  paste(charset[idx], collapse = "")
}

.member_density_plot <- function(x_num, kind, options = list()) {
  cfg <- .member_density_defaults(options)
  n_total <- length(x_num)

  if (n_total < cfg$min_n) {
    return(.new_density_result(
      kind = kind,
      bins_used = 0L,
      n_used = n_total,
      sampled = FALSE,
      skipped_reason = "too few values"
    ))
  }

  if (n_total > cfg$hard_limit) {
    return(.new_density_result(
      kind = kind,
      bins_used = 0L,
      n_used = n_total,
      sampled = FALSE,
      skipped_reason = "input too large"
    ))
  }

  sampled <- FALSE
  x_used <- x_num
  if (n_total > cfg$max_sample) {
    step <- max(1L, ceiling(n_total / cfg$max_sample))
    idx <- seq.int(1L, n_total, by = step)
    if (length(idx) > cfg$max_sample) {
      idx <- idx[seq_len(cfg$max_sample)]
    }
    x_used <- x_num[idx]
    sampled <- TRUE
  }

  x_used <- x_used[is.finite(x_used)]
  if (length(x_used) < cfg$min_n) {
    return(.new_density_result(
      kind = kind,
      bins_used = 0L,
      n_used = length(x_used),
      sampled = sampled,
      skipped_reason = "too few finite values"
    ))
  }

  bins <- max(6L, cfg$bins)
  width <- max(16L, cfg$width)
  height <- max(6L, cfg$height)
  density_plot <- NULL

  if (requireNamespace("txtplot", quietly = TRUE)) {
    density_lines <- tryCatch(
      suppressWarnings(capture.output(txtplot::txtdensity(x_used, width = width, height = height))),
      error = function(e) character(0)
    )
    if (length(density_lines) > 0L) {
      density_plot <- paste(density_lines, collapse = "\n")
    }
  }

  if (!is.character(density_plot) || !nzchar(density_plot)) {
    density_plot <- .member_density_fallback(x_used, bins)
  }
  if (!nzchar(density_plot)) {
    return(.new_density_result(
      kind = kind,
      bins_used = 0L,
      n_used = length(x_used),
      sampled = sampled,
      skipped_reason = "density render failed"
    ))
  }

  .new_density_result(
    kind = kind,
    bins_used = bins,
    n_used = length(x_used),
    sampled = sampled,
    density_plot = density_plot
  )
}

.member_stats <- function(x, options = list()) {
  if (is.null(x) || length(x) == 0L || !is.atomic(x)) return(NULL)

  x_used <- x
  sample_meta <- NULL
  max_rows <- suppressWarnings(as.integer(options$member_stats_max_rows %||% NA_integer_))
  if (!is.na(max_rows) && max_rows > 0L && length(x) > max_rows) {
    step <- max(1L, ceiling(length(x) / max_rows))
    idx <- seq.int(1L, length(x), by = step)
    if (length(idx) > max_rows) {
      idx <- idx[seq_len(max_rows)]
    }
    x_used <- x[idx]
    sample_meta <- list(
      sampled = TRUE,
      n_used = as.integer(length(x_used)),
      n_total = as.integer(length(x))
    )
  }

  missing_n <- sum(is.na(x_used))
  missing_pct <- round((missing_n / length(x_used)) * 100, 2)
  out <- list(
    missing_n = as.integer(missing_n),
    missing_pct = missing_pct
  )
  if (!is.null(sample_meta)) {
    out$sample_meta <- sample_meta
  }

  if (is.numeric(x_used) || is.integer(x_used)) {
    x_num <- x_used[!is.na(x_used)]
    out$unique_n <- as.integer(length(unique(x_num)))
    if (length(x_num) > 0L) {
      out$numeric_summary <- list(
        min = as.numeric(min(x_num)),
        median = as.numeric(stats::median(x_num)),
        mean = as.numeric(mean(x_num)),
        max = as.numeric(max(x_num))
      )
      out$top_values <- .member_top_values(round(x_num, 5L))
      density <- .member_density_plot(x_num, kind = "numeric", options = options)
      out$density_plot <- density$density_plot
      out$density_meta <- density$density_meta
    }
    return(out)
  }

  if (is.factor(x_used) && is.ordered(x_used)) {
    x_ord <- x_used[!is.na(x_used)]
    out$unique_n <- as.integer(length(unique(x_ord)))
    out$top_values <- .member_top_values(as.character(x_ord))
    density <- .member_density_plot(as.numeric(x_ord), kind = "ordered_factor", options = options)
    out$density_plot <- density$density_plot
    out$density_meta <- density$density_meta
    return(out)
  }

  if (is.character(x_used) || is.factor(x_used) || is.logical(x_used)) {
    x_clean <- x_used[!is.na(x_used)]
    out$unique_n <- as.integer(length(unique(x_clean)))
    out$top_values <- .member_top_values(x_clean)
    return(out)
  }

  NULL
}
