.normalize_request_profile <- function(options = list()) {
  profile <- options$request_profile %||% "interactive_rich"
  profile <- as.character(profile)
  if (length(profile) < 1L || !nzchar(profile[[1L]])) {
    return("interactive_rich")
  }
  profile <- profile[[1L]]
  if (!profile %in% c("completion_lean", "interactive_rich", "meta_only")) {
    return("interactive_rich")
  }
  profile
}

.normalize_member_name_filter <- function(options = list()) {
  member_filter <- options$member_name_filter %||% NULL
  if (is.null(member_filter)) {
    return(NULL)
  }

  member_filter <- as.character(member_filter)
  if (length(member_filter) < 1L) {
    return(NULL)
  }

  member_filter <- trimws(member_filter)
  member_filter <- member_filter[nzchar(member_filter)]
  if (length(member_filter) < 1L) {
    return(NULL)
  }

  unique(member_filter)
}

.normalize_member_name_prefix <- function(options = list()) {
  member_prefix <- options$member_name_prefix %||% NULL
  if (is.null(member_prefix)) {
    return(NULL)
  }

  member_prefix <- as.character(member_prefix)
  if (length(member_prefix) < 1L) {
    return(NULL)
  }

  member_prefix <- trimws(member_prefix[[1L]])
  if (!nzchar(member_prefix)) {
    return(NULL)
  }

  member_prefix
}

.object_summary_fast <- function(obj, max_chars = 120L) {
  cls <- class(obj)
  cls_txt <- if (length(cls) > 0L) cls[[1L]] else typeof(obj)
  txt <- sprintf("%s (%s, len=%d)", cls_txt, typeof(obj), length(obj))
  if (nchar(txt, type = "bytes") > max_chars) {
    paste0(substr(txt, 1L, max_chars - 3L), "...")
  } else {
    txt
  }
}

.object_meta <- function(obj, options = list(), profile = "interactive_rich") {
  source_class <- attr(obj, "rscope_source_class", exact = TRUE)
  if (!is.null(source_class)) {
    source_class <- as.character(source_class)
  }

  summary <- .member_summary(obj, max_chars = options$max_summary_chars %||% 120L)
  if (identical(profile, "completion_lean") || identical(profile, "meta_only")) {
    summary <- .object_summary_fast(obj, max_chars = options$max_summary_chars %||% 120L)
  }

  list(
    class = class(obj),
    source_class = source_class,
    type = typeof(obj),
    length = length(obj),
    summary = summary
  )
}

.default_accessor <- function(obj, options = list()) {
  accessor <- options$accessor %||% NULL
  if (!is.null(accessor)) return(accessor)
  if (isS4(obj)) return("@")
  if (is.function(obj)) return("arg")
  "$"
}

.member_type <- function(value, accessor) {
  if (identical(accessor, "arg")) {
    return("argument")
  }
  if (is.null(value)) {
    return("NULL")
  }
  typeof(value)
}

.formal_default_summary <- function(fn, name, max_chars = 80L) {
  fml <- formals(fn)
  if (is.null(fml)) {
    return("<required>")
  }
  fml_names <- names(fml)
  if (is.null(fml_names)) {
    return("<required>")
  }
  idx <- match(name, fml_names)
  if (is.na(idx)) {
    return("<required>")
  }
  txt <- paste(deparse(fml[[idx]]), collapse = " ")
  txt <- trimws(txt)
  if (!nzchar(txt)) {
    return("<required>")
  }
  if (nchar(txt, type = "bytes") > max_chars) {
    return(paste0(substr(txt, 1L, max_chars - 3L), "..."))
  }
  txt
}

inspect_object <- function(obj, options = list()) {
  profile <- .normalize_request_profile(options)
  member_name_filter <- .normalize_member_name_filter(options)
  member_name_prefix <- .normalize_member_name_prefix(options)
  lean_mode <- identical(profile, "completion_lean")
  meta_only_mode <- identical(profile, "meta_only")
  accessor <- .default_accessor(obj, options)
  max_members <- as.integer(options$max_members %||% 200L)
  include_member_stats <- options$include_member_stats
  if (is.null(include_member_stats)) {
    include_member_stats <- TRUE
  }
  include_member_stats <- isTRUE(include_member_stats)
  if (lean_mode || meta_only_mode) {
    include_member_stats <- FALSE
  }
  enrichment_budget_ms <- suppressWarnings(as.numeric(options$enrichment_budget_ms %||% NA_real_))
  if (is.na(enrichment_budget_ms) || enrichment_budget_ms <= 0) {
    enrichment_budget_ms <- NA_real_
  }
  budget_start_ms <- as.numeric(proc.time()[[3L]]) * 1000
  names_all <- .member_names(obj, accessor, options)

  truncated <- FALSE
  summary_note <- NULL
  if (!is.null(member_name_filter)) {
    idx <- match(member_name_filter, names_all, nomatch = 0L)
    idx <- idx[idx > 0L]
    names_all <- names_all[idx]
    if (length(names_all) < length(member_name_filter)) {
      summary_note <- sprintf(
        "member filter matched %d/%d",
        length(names_all),
        length(member_name_filter)
      )
    }
  } else if (!is.null(member_name_prefix)) {
    names_norm <- tolower(names_all)
    prefix_norm <- tolower(member_name_prefix)
    idx <- startsWith(names_norm, prefix_norm)
    names_all <- names_all[idx]
  } else if (length(names_all) > max_members) {
    truncated <- TRUE
    summary_note <- sprintf("member list truncated to %d/%d", max_members, length(names_all))
    names_all <- names_all[seq_len(max_members)]
  }

  make_lean_member <- function(name) {
    if (identical(accessor, "arg") && is.function(obj)) {
      return(list(
        name_raw = name,
        name_display = name,
        accessor = accessor,
        insert_text = .member_insert_text(name, accessor),
        completion_text = .member_completion_text(name, accessor),
        summary = "",
        type = "argument",
        size = 1L,
        member_stats = NULL
      ))
    }

    list(
      name_raw = name,
      name_display = name,
      accessor = accessor,
      insert_text = .member_insert_text(name, accessor),
      completion_text = .member_completion_text(name, accessor),
      summary = "",
      type = "unknown",
      size = 0L,
      member_stats = NULL
    )
  }

  members <- lapply(names_all, function(name) {
    if (lean_mode || meta_only_mode) {
      return(make_lean_member(name))
    }

    if (!is.na(enrichment_budget_ms)) {
      elapsed_ms <- (as.numeric(proc.time()[[3L]]) * 1000) - budget_start_ms
      if (elapsed_ms > enrichment_budget_ms) {
        return(make_lean_member(name))
      }
    }

    if (identical(accessor, "arg") && is.function(obj)) {
      return(list(
        name_raw = name,
        name_display = name,
        accessor = accessor,
        insert_text = .member_insert_text(name, accessor),
        completion_text = .member_completion_text(name, accessor),
        summary = .formal_default_summary(obj, name, max_chars = options$max_summary_chars %||% 80L),
        type = "argument",
        size = 1L,
        member_stats = NULL
      ))
    }

    value <- tryCatch(.member_value(obj, accessor, name), error = function(e) NULL)
    stats <- NULL
    if (include_member_stats) {
      stats <- tryCatch(.member_stats(value, options = options), error = function(e) NULL)
    }
    list(
      name_raw = name,
      name_display = name,
      accessor = accessor,
      insert_text = .member_insert_text(name, accessor),
      completion_text = .member_completion_text(name, accessor),
      summary = .member_summary(value, max_chars = options$max_summary_chars %||% 80L),
      type = .member_type(value, accessor),
      size = .member_size(value),
      member_stats = stats
    )
  })

  list(
    object_meta = utils::modifyList(
      .object_meta(obj, options, profile = profile),
      list(
        truncated = truncated,
        summary_note = summary_note,
        request_profile = profile
      )
    ),
    members = members
  )
}
