.ark_parse_help_topic <- function(topic) {
  topic <- as.character(topic %||% "")
  if (length(topic) < 1L || !nzchar(topic[[1L]])) {
    return(list(topic = "", package = NULL))
  }

  topic <- trimws(topic[[1L]])

  match <- regexec("^([A-Za-z.][A-Za-z0-9._]*):::([A-Za-z.][A-Za-z0-9._]*)$", topic)
  parsed <- regmatches(topic, match)[[1L]]
  if (length(parsed) == 3L) {
    return(list(topic = parsed[[3L]], package = parsed[[2L]]))
  }

  match <- regexec("^([A-Za-z.][A-Za-z0-9._]*)::([A-Za-z.][A-Za-z0-9._]*)$", topic)
  parsed <- regmatches(topic, match)[[1L]]
  if (length(parsed) == 3L) {
    return(list(topic = parsed[[3L]], package = parsed[[2L]]))
  }

  list(topic = topic, package = NULL)
}

.ark_help_hook_state <- new.env(parent = emptyenv())
.ark_help_hook_state$installed <- FALSE
.ark_help_hook_state$original <- NULL
.ark_help_hook_state$original_help <- NULL
.ark_help_hook_state$original_help_print <- NULL
.ark_help_hook_state$original_view <- NULL
.ark_help_hook_state$original_utils_view <- NULL
.ark_help_hook_state$status_file <- ""
.ark_help_hook_state$nvim_bin <- ""
.ark_help_hook_state$last_error <- NULL
.ark_help_hook_state$last_topic <- NULL
.ark_help_hook_state$last_success_at <- NULL

.ark_help_hook_enabled <- function() {
  value <- tolower(Sys.getenv("ARK_NVIM_HELP_HOOK", unset = "1"))
  !value %in% c("0", "false", "no", "off")
}

.ark_view_hook_enabled <- function() {
  value <- tolower(Sys.getenv("ARK_NVIM_VIEW_HOOK", unset = "1"))
  !value %in% c("0", "false", "no", "off")
}

.ark_help_topic_from_expr <- function(topic_expr) {
  if (is.call(topic_expr) && identical(topic_expr[[1L]], quote(`?`))) {
    return(NULL)
  }

  package <- NULL
  if (is.call(topic_expr) &&
      length(topic_expr) >= 3L &&
      (identical(topic_expr[[1L]], quote(`::`)) || identical(topic_expr[[1L]], quote(`:::`)))) {
    package <- as.character(topic_expr[[2L]])
    topic_expr <- topic_expr[[3L]]
  }

  if (is.name(topic_expr)) {
    topic <- as.character(topic_expr)
  } else if (is.character(topic_expr) && length(topic_expr) == 1L) {
    topic <- topic_expr[[1L]]
  } else {
    return(NULL)
  }

  if (!nzchar(topic)) {
    return(NULL)
  }

  if (!is.null(package) && length(package) == 1L && nzchar(package)) {
    return(paste0(package, "::", topic))
  }

  topic
}

.ark_help_status_file <- function() {
  status_file <- .ark_help_hook_state$status_file %||% ""
  if (is.character(status_file) && length(status_file) == 1L && nzchar(status_file)) {
    return(status_file)
  }

  status_file <- Sys.getenv("ARK_SESSION_STATUS_FILE", unset = "")
  if (nzchar(status_file)) {
    return(status_file)
  }

  status_root <- Sys.getenv("ARK_STATUS_DIR", unset = "")
  session_id <- Sys.getenv("ARK_SESSION_ID", unset = "")
  if (!nzchar(status_root) || !nzchar(session_id)) {
    return("")
  }

  file.path(status_root, paste0(session_id, ".json"))
}

.ark_help_status_payload <- function() {
  status_file <- .ark_help_status_file()
  if (!nzchar(status_file) || !file.exists(status_file)) {
    return(NULL)
  }

  tryCatch(
    jsonlite::fromJSON(
      paste(readLines(status_file, warn = FALSE), collapse = "\n"),
      simplifyVector = FALSE
    ),
    error = function(e) NULL
  )
}

.ark_help_first_nonempty <- function(...) {
  for (value in list(...)) {
    if (is.character(value) && length(value) == 1L && nzchar(value)) {
      return(value)
    }
  }

  ""
}

.ark_neovim_callback_target <- function(console_function_name, parent_function_name) {
  payload <- .ark_help_status_payload()
  console_socket <- payload$nvim_console_rpc_socket %||% ""
  if (is.character(console_socket) && length(console_socket) == 1L && nzchar(console_socket)) {
    return(list(
      server = console_socket,
      function_name = console_function_name,
      nvim_bin = .ark_help_first_nonempty(
        .ark_help_hook_state$nvim_bin,
        Sys.getenv("ARK_NVIM_CONSOLE_NVIM", unset = ""),
        "nvim"
      )
    ))
  }

  parent_server <- Sys.getenv("ARK_NVIM_PARENT_SERVER", unset = "")
  if (is.character(parent_server) && length(parent_server) == 1L && nzchar(parent_server)) {
    return(list(
      server = parent_server,
      function_name = parent_function_name,
      nvim_bin = .ark_help_first_nonempty(
        Sys.getenv("ARK_NVIM_PARENT_NVIM", unset = ""),
        .ark_help_hook_state$nvim_bin,
        "nvim"
      )
    ))
  }

  NULL
}

.ark_help_callback_target <- function() {
  .ark_neovim_callback_target("__ark_console_rpc_ark_help", "__ark_nvim_help_rpc")
}

.ark_view_callback_target <- function() {
  .ark_neovim_callback_target("__ark_console_rpc_ark_view", "__ark_nvim_view_rpc")
}

.ark_help_hook_target_available <- function() {
  !is.null(.ark_help_callback_target())
}

.ark_vim_string <- function(value) {
  value <- as.character(value %||% "")
  if (length(value) != 1L || grepl("[\r\n]", value)) {
    return(NULL)
  }

  paste0("'", gsub("'", "''", value, fixed = TRUE), "'")
}

.ark_request_neovim_help <- function(topic) {
  target <- .ark_help_callback_target()
  if (is.null(target)) {
    .ark_help_hook_state$last_error <- "Ark Neovim help RPC target is unavailable"
    return(FALSE)
  }

  topic_arg <- .ark_vim_string(topic)
  if (is.null(topic_arg)) {
    .ark_help_hook_state$last_error <- "ArkHelp topic cannot be encoded"
    return(FALSE)
  }

  nvim_bin <- target$nvim_bin %||% .ark_help_hook_state$nvim_bin %||% ""
  if (!is.character(nvim_bin) || length(nvim_bin) != 1L || !nzchar(nvim_bin)) {
    nvim_bin <- "nvim"
  }
  if (!nzchar(nvim_bin)) {
    nvim_bin <- "nvim"
  }

  expr <- paste0("v:lua.", target$function_name, "(", topic_arg, ")")
  output <- tryCatch(
    withCallingHandlers(
      system2(
        nvim_bin,
        c("--headless", "--server", shQuote(target$server), "--remote-expr", shQuote(expr)),
        stdout = TRUE,
        stderr = TRUE
      ),
      warning = function(w) {
        if (!is.null(findRestart("muffleWarning"))) {
          invokeRestart("muffleWarning")
        }
      }
    ),
    error = function(e) structure(conditionMessage(e), status = 1L)
  )
  status <- attr(output, "status", exact = TRUE)
  if (is.null(status)) {
    status <- 0L
  }
  output_text <- trimws(paste(as.character(output), collapse = "\n"))
  if (identical(output_text, "ok")) {
    .ark_help_hook_state$last_error <- NULL
    .ark_help_hook_state$last_topic <- topic
    .ark_help_hook_state$last_success_at <- Sys.time()
    return(TRUE)
  }

  .ark_help_hook_state$last_error <- output_text
  FALSE
}

.ark_request_neovim_view <- function(expr) {
  target <- .ark_view_callback_target()
  if (is.null(target)) {
    .ark_help_hook_state$last_error <- "Ark Neovim View RPC target is unavailable"
    return(FALSE)
  }

  expr_arg <- .ark_vim_string(expr)
  if (is.null(expr_arg)) {
    .ark_help_hook_state$last_error <- "ArkView expression cannot be encoded"
    return(FALSE)
  }

  nvim_bin <- target$nvim_bin %||% .ark_help_hook_state$nvim_bin %||% ""
  if (!is.character(nvim_bin) || length(nvim_bin) != 1L || !nzchar(nvim_bin)) {
    nvim_bin <- "nvim"
  }
  if (!nzchar(nvim_bin)) {
    nvim_bin <- "nvim"
  }

  remote_expr <- paste0("v:lua.", target$function_name, "(", expr_arg, ")")
  output <- tryCatch(
    withCallingHandlers(
      system2(
        nvim_bin,
        c("--headless", "--server", shQuote(target$server), "--remote-expr", shQuote(remote_expr)),
        stdout = TRUE,
        stderr = TRUE
      ),
      warning = function(w) {
        if (!is.null(findRestart("muffleWarning"))) {
          invokeRestart("muffleWarning")
        }
      }
    ),
    error = function(e) structure(conditionMessage(e), status = 1L)
  )
  output_text <- trimws(paste(as.character(output), collapse = "\n"))
  if (identical(output_text, "ok")) {
    .ark_help_hook_state$last_error <- NULL
    return(TRUE)
  }

  .ark_help_hook_state$last_error <- output_text
  FALSE
}

.ark_original_help_operator <- function() {
  original <- .ark_help_hook_state$original
  if (!is.function(original)) {
    original <- get("?", envir = asNamespace("utils"), inherits = FALSE)
  }
  original
}

.ark_original_help_function <- function() {
  original <- .ark_help_hook_state$original_help
  if (!is.function(original)) {
    original <- get("help", envir = asNamespace("utils"), inherits = FALSE)
  }
  original
}

.ark_original_help_print_function <- function() {
  original <- .ark_help_hook_state$original_help_print
  if (!is.function(original)) {
    original <- get("print.help_files_with_topic", envir = asNamespace("utils"), inherits = FALSE)
  }
  original
}

.ark_original_view_function <- function() {
  original <- .ark_help_hook_state$original_view
  if (!is.function(original)) {
    original <- .ark_help_hook_state$original_utils_view
  }
  if (!is.function(original)) {
    original <- get("View", envir = asNamespace("utils"), inherits = FALSE)
  }
  original
}

.ark_original_utils_view_function <- function() {
  original <- .ark_help_hook_state$original_utils_view
  if (!is.function(original)) {
    original <- get("View", envir = asNamespace("utils"), inherits = FALSE)
  }
  original
}

.ark_view_expr_from_arg <- function(x_expr) {
  expr <- tryCatch(
    paste(deparse(x_expr, width.cutoff = 500L), collapse = " "),
    error = function(e) ""
  )
  expr <- trimws(expr)
  if (!nzchar(expr) || identical(expr, "<missing>") || grepl("[\r\n]", expr)) {
    return(NULL)
  }

  expr
}

.ark_view_dispatch <- function(x_missing, x_expr, original, call, parent_frame) {
  if (!isTRUE(x_missing)) {
    expr <- .ark_view_expr_from_arg(x_expr)
    if (!is.null(expr) && .ark_request_neovim_view(expr)) {
      return(invisible())
    }
  }

  call[[1L]] <- original
  eval(call, envir = parent_frame)
}

.ark_view_function <- function(x, title) {
  .ark_view_dispatch(
    missing(x),
    substitute(x),
    .ark_original_view_function(),
    match.call(expand.dots = FALSE),
    parent.frame()
  )
}

.ark_utils_view_function <- function(x, title) {
  .ark_view_dispatch(
    missing(x),
    substitute(x),
    .ark_original_utils_view_function(),
    match.call(expand.dots = FALSE),
    parent.frame()
  )
}

.ark_call_original_help <- function(topic_expr, type_expr = NULL, has_type = FALSE, parent_frame = parent.frame()) {
  original <- .ark_original_help_operator()
  args <- if (isTRUE(has_type)) list(type_expr, topic_expr) else list(topic_expr)
  eval(as.call(c(list(original), args)), envir = parent_frame)
}

.ark_help_operator <- function(e1, e2) {
  parent_frame <- parent.frame()

  if (missing(e2)) {
    topic <- .ark_help_topic_from_expr(substitute(e1))
    if (!is.null(topic) && .ark_request_neovim_help(topic)) {
      return(invisible())
    }

    return(.ark_call_original_help(substitute(e1), parent_frame = parent_frame))
  }

  .ark_call_original_help(
    substitute(e2),
    type_expr = substitute(e1),
    has_type = TRUE,
    parent_frame = parent_frame
  )
}

.ark_help_arg_package <- function(package_expr, package_value) {
  if (is.character(package_value) && length(package_value) == 1L && nzchar(package_value)) {
    return(package_value)
  }

  if (is.name(package_expr)) {
    package <- as.character(package_expr)
    if (nzchar(package)) {
      return(package)
    }
  }

  NULL
}

.ark_help_arg_topic <- function(topic_expr, topic_value) {
  if (is.name(topic_expr)) {
    topic <- as.character(topic_expr)
    if (nzchar(topic)) {
      return(topic)
    }
  }

  if (is.character(topic_value) && length(topic_value) == 1L && nzchar(topic_value)) {
    return(topic_value)
  }

  NULL
}

.ark_help_arg_type_supported <- function(explicit, value) {
  if (!isTRUE(explicit)) {
    return(TRUE)
  }

  if (is.null(value) || !length(value)) {
    return(TRUE)
  }

  help_type <- tolower(as.character(value[[1L]] %||% ""))
  !nzchar(help_type) || identical(help_type, "text")
}

.ark_help_recent_success <- function(topic) {
  previous_topic <- .ark_help_hook_state$last_topic
  previous_time <- .ark_help_hook_state$last_success_at
  if (!is.character(previous_topic) || length(previous_topic) != 1L || !identical(previous_topic, topic)) {
    return(FALSE)
  }
  if (is.null(previous_time)) {
    return(FALSE)
  }

  age <- tryCatch(
    as.numeric(difftime(Sys.time(), previous_time, units = "secs")),
    error = function(e) Inf
  )
  is.finite(age) && age >= 0 && age < 2
}

.ark_help_topic_from_help_args <- function(topic_expr,
                                           topic_value,
                                           package_expr,
                                           package_value,
                                           explicit_help_type = FALSE,
                                           help_type_value = NULL,
                                           has_lib_loc = FALSE) {
  if (isTRUE(has_lib_loc) || !.ark_help_arg_type_supported(explicit_help_type, help_type_value)) {
    return(NULL)
  }

  topic <- .ark_help_arg_topic(topic_expr, topic_value)
  if (is.null(topic)) {
    return(NULL)
  }

  package <- .ark_help_arg_package(package_expr, package_value)
  if (!is.null(package)) {
    return(paste0(package, "::", topic))
  }

  topic
}

.ark_help_topic_from_help_object <- function(x) {
  topic <- attr(x, "topic", exact = TRUE)
  if (!is.character(topic) || length(topic) != 1L || !nzchar(topic)) {
    return(NULL)
  }

  type <- attr(x, "type", exact = TRUE)
  if (is.character(type) && length(type) == 1L && nzchar(type) && !identical(tolower(type), "text")) {
    return(NULL)
  }

  paths <- as.character(x)
  if (length(paths) == 1L && nzchar(paths[[1L]])) {
    package <- basename(dirname(dirname(paths[[1L]])))
    if (is.character(package) && length(package) == 1L && nzchar(package)) {
      return(paste0(package, "::", topic))
    }
  }

  topic
}

.ark_help_print_function <- function(x, ...) {
  topic <- .ark_help_topic_from_help_object(x)
  if (!is.null(topic)) {
    if (.ark_help_recent_success(topic) || .ark_request_neovim_help(topic)) {
      return(invisible(x))
    }
  }

  .ark_original_help_print_function()(x, ...)
}

.ark_help_function <- function(topic,
                               package = NULL,
                               lib.loc = NULL,
                               verbose = getOption("verbose"),
                               try.all.packages = getOption("help.try.all.packages"),
                               help_type = getOption("help_type")) {
  parent_frame <- parent.frame()

  if (!missing(topic)) {
    topic_expr <- substitute(topic)
    topic_value <- if (is.name(topic_expr)) {
      NULL
    } else {
      tryCatch(topic, error = function(e) NULL)
    }
    package_expr <- if (missing(package)) NULL else substitute(package)
    package_value <- if (missing(package)) {
      NULL
    } else {
      tryCatch(package, error = function(e) NULL)
    }
    help_type_value <- if (missing(help_type)) {
      NULL
    } else {
      tryCatch(help_type, error = function(e) NULL)
    }

    topic_name <- .ark_help_topic_from_help_args(
      topic_expr,
      topic_value,
      package_expr,
      package_value,
      explicit_help_type = !missing(help_type),
      help_type_value = help_type_value,
      has_lib_loc = !missing(lib.loc)
    )
    if (!is.null(topic_name) && .ark_request_neovim_help(topic_name)) {
      return(invisible())
    }
  }

  call <- match.call(expand.dots = FALSE)
  call[[1L]] <- .ark_original_help_function()
  eval(call, envir = parent_frame)
}

.ark_install_utils_help_hook <- function() {
  utils_ns <- asNamespace("utils")
  existing <- get("help", envir = utils_ns, inherits = FALSE)
  if (identical(existing, .ark_help_function)) {
    return(TRUE)
  }

  if (!is.function(.ark_help_hook_state$original_help)) {
    .ark_help_hook_state$original_help <- existing
  }

  tryCatch({
    was_locked <- bindingIsLocked("help", utils_ns)
    if (was_locked) {
      unlockBinding("help", utils_ns)
    }
    on.exit({
      if (was_locked && !bindingIsLocked("help", utils_ns)) {
        lockBinding("help", utils_ns)
      }
    }, add = TRUE)

    assign("help", .ark_help_function, envir = utils_ns)
    TRUE
  }, error = function(e) {
    .ark_help_hook_state$last_error <- conditionMessage(e)
    FALSE
  })
}

.ark_install_utils_help_print_hook <- function() {
  utils_ns <- asNamespace("utils")
  existing <- get("print.help_files_with_topic", envir = utils_ns, inherits = FALSE)
  if (identical(existing, .ark_help_print_function)) {
    return(TRUE)
  }

  if (!is.function(.ark_help_hook_state$original_help_print)) {
    .ark_help_hook_state$original_help_print <- existing
  }

  tryCatch({
    was_locked <- bindingIsLocked("print.help_files_with_topic", utils_ns)
    if (was_locked) {
      unlockBinding("print.help_files_with_topic", utils_ns)
    }
    on.exit({
      if (was_locked && !bindingIsLocked("print.help_files_with_topic", utils_ns)) {
        lockBinding("print.help_files_with_topic", utils_ns)
      }
    }, add = TRUE)

    assign("print.help_files_with_topic", .ark_help_print_function, envir = utils_ns)
    registerS3method("print", "help_files_with_topic", .ark_help_print_function, envir = utils_ns)
    TRUE
  }, error = function(e) {
    .ark_help_hook_state$last_error <- conditionMessage(e)
    FALSE
  })
}

.ark_install_global_view_hook <- function() {
  target_env <- .GlobalEnv
  existing <- if (exists("View", envir = target_env, inherits = FALSE)) {
    get("View", envir = target_env, inherits = FALSE)
  } else {
    get("View", envir = asNamespace("utils"), inherits = FALSE)
  }

  if (identical(existing, .ark_view_function)) {
    return(TRUE)
  }

  if (!is.function(.ark_help_hook_state$original_view)) {
    .ark_help_hook_state$original_view <- existing
  }

  assign("View", .ark_view_function, envir = target_env)
  TRUE
}

.ark_install_utils_view_hook <- function() {
  utils_ns <- asNamespace("utils")
  existing <- get("View", envir = utils_ns, inherits = FALSE)
  if (identical(existing, .ark_utils_view_function)) {
    return(TRUE)
  }

  if (!is.function(.ark_help_hook_state$original_utils_view)) {
    .ark_help_hook_state$original_utils_view <- existing
  }

  tryCatch({
    was_locked <- bindingIsLocked("View", utils_ns)
    if (was_locked) {
      unlockBinding("View", utils_ns)
    }
    on.exit({
      if (was_locked && !bindingIsLocked("View", utils_ns)) {
        lockBinding("View", utils_ns)
      }
    }, add = TRUE)

    assign("View", .ark_utils_view_function, envir = utils_ns)
    TRUE
  }, error = function(e) {
    .ark_help_hook_state$last_error <- conditionMessage(e)
    FALSE
  })
}

.ark_install_help_hook <- function(options = list()) {
  status_file <- options$status_file %||% ""
  if (is.character(status_file) && length(status_file) == 1L) {
    .ark_help_hook_state$status_file <- status_file
  }

  nvim_bin <- options$nvim_bin %||% ""
  if (is.character(nvim_bin) && length(nvim_bin) == 1L) {
    .ark_help_hook_state$nvim_bin <- nvim_bin
  }

  if (!.ark_help_hook_enabled() || !.ark_help_hook_target_available()) {
    return(FALSE)
  }

  if (!.ark_install_utils_help_hook()) {
    return(FALSE)
  }
  if (!.ark_install_utils_help_print_hook()) {
    return(FALSE)
  }
  if (.ark_view_hook_enabled()) {
    if (!.ark_install_global_view_hook()) {
      return(FALSE)
    }
    if (!.ark_install_utils_view_hook()) {
      return(FALSE)
    }
  }

  target_env <- .GlobalEnv
  existing <- if (exists("?", envir = target_env, inherits = FALSE)) {
    get("?", envir = target_env, inherits = FALSE)
  } else {
    get("?", envir = asNamespace("utils"), inherits = FALSE)
  }

  if (identical(existing, .ark_help_operator)) {
    .ark_help_hook_state$installed <- TRUE
    return(TRUE)
  }

  .ark_help_hook_state$original <- existing
  assign("?", .ark_help_operator, envir = target_env)
  .ark_help_hook_state$installed <- TRUE
  TRUE
}

.ark_help_to_rd <- function(help_page) {
  if (inherits(help_page, "dev_topic")) {
    return(tools::parse_Rd(help_page$path))
  }

  rd_obj <- tryCatch(
    getFromNamespace(".getHelpFile", "utils")(help_page),
    error = function(e) NULL
  )
  if (!is.null(rd_obj)) {
    return(rd_obj)
  }

  help_path <- as.character(help_page)
  rd_name <- basename(help_path)
  rd_package <- basename(dirname(dirname(help_path)))
  tools::Rd_db(rd_package)[[paste0(rd_name, ".Rd")]]
}

.ark_help_page_package <- function(help_page, fallback = NULL) {
  if (!is.null(fallback) && nzchar(fallback %||% "")) {
    return(fallback)
  }

  if (inherits(help_page, "dev_topic")) {
    return(help_page$pkg %||% fallback)
  }

  help_path <- as.character(help_page)
  if (!length(help_path)) {
    return(fallback)
  }

  basename(dirname(dirname(help_path[[1L]])))
}

.ark_strip_overstrike <- function(text) {
  if (is.null(text) || !nzchar(text)) {
    return(text)
  }

  text <- enc2utf8(text)
  if (!grepl("\b", text, fixed = TRUE)) {
    return(text)
  }

  repeat {
    stripped <- gsub(".\b", "", text, perl = TRUE)
    if (identical(stripped, text)) {
      return(gsub("\b", "", stripped, fixed = TRUE))
    }
    if (!grepl("\b", stripped, fixed = TRUE)) {
      return(stripped)
    }
    text <- stripped
  }
}

.ark_flatten_rd_text <- function(node) {
  if (is.null(node)) {
    return("")
  }

  if (is.character(node)) {
    return(paste(node, collapse = ""))
  }

  if (!is.list(node)) {
    return("")
  }

  pieces <- vapply(node, .ark_flatten_rd_text, character(1), USE.NAMES = FALSE)
  paste(pieces, collapse = "")
}

.ark_link_target <- function(label, rd_option = NULL, default_package = NULL) {
  option <- trimws(as.character(rd_option %||% ""))
  label <- trimws(as.character(label %||% ""))

  if (nzchar(option)) {
    if (startsWith(option, "=")) {
      return(list(topic = substring(option, 2L), package = default_package))
    }

    if (grepl(":", option, fixed = TRUE)) {
      parts <- strsplit(option, ":", fixed = TRUE)[[1L]]
      if (length(parts) >= 2L) {
        return(list(
          topic = paste(parts[-1L], collapse = ":"),
          package = parts[[1L]]
        ))
      }
    }

    return(list(topic = option, package = default_package))
  }

  if (!nzchar(label)) {
    return(NULL)
  }

  topic <- sub("^\\?+", "", label)
  topic <- sub("\\(\\)$", "", topic)
  if (!nzchar(topic)) {
    return(NULL)
  }

  list(topic = topic, package = default_package)
}

.ark_collect_help_links <- function(node, default_package = NULL) {
  if (is.null(node) || !is.list(node)) {
    return(list())
  }

  links <- list()
  tag <- attr(node, "Rd_tag", exact = TRUE)
  if (identical(tag, "\\link")) {
    label <- trimws(.ark_flatten_rd_text(node))
    target <- .ark_link_target(label, attr(node, "Rd_option", exact = TRUE), default_package)
    if (!is.null(target) && nzchar(target$topic %||% "") && nzchar(label)) {
      links[[length(links) + 1L]] <- list(
        label = label,
        topic = target$topic,
        package = target$package
      )
    }
  }

  for (child in node) {
    child_links <- .ark_collect_help_links(child, default_package)
    if (length(child_links)) {
      links <- c(links, child_links)
    }
  }

  if (!length(links)) {
    return(links)
  }

  keys <- vapply(links, function(link) {
    paste(link$label %||% "", link$package %||% "", link$topic %||% "", sep = "::")
  }, character(1), USE.NAMES = FALSE)

  links[!duplicated(keys)]
}

.ark_render_help_page <- function(topic, package = NULL) {
  original_help <- .ark_original_help_function()
  if (is.null(package)) {
    help_page <- do.call(original_help, list(
      topic = topic,
      help_type = "text",
      try.all.packages = TRUE
    ))
  } else {
    help_page <- do.call(original_help, list(
      topic = topic,
      package = package,
      help_type = "text"
    ))
  }
  if (length(help_page) < 1L) {
    return(NULL)
  }

  target_page <- if (inherits(help_page, "dev_topic")) help_page else help_page[[1L]]
  rd_obj <- .ark_help_to_rd(target_page)
  default_package <- .ark_help_page_package(target_page, package)

  list(
    text = .ark_strip_overstrike(paste(capture.output(tools::Rd2txt(rd_obj)), collapse = "\n")),
    references = .ark_collect_help_links(rd_obj, default_package)
  )
}

.ark_render_help_text <- function(topic, package = NULL) {
  page <- .ark_render_help_page(topic, package)
  if (is.null(page)) {
    return(NULL)
  }
  page$text
}

.ark_help_text_payload <- function(session, topic) {
  parsed <- .ark_parse_help_topic(topic)
  if (!nzchar(parsed$topic %||% "")) {
    return(.emit_json(.new_error_payload(
      "E_IPC_REQUEST",
      "missing topic",
      "ipc_request",
      session
    )))
  }

  tryCatch({
    page <- .ark_render_help_page(parsed$topic, parsed$package)
    .emit_json(list(
      schema_version = .ark_schema_version(),
      status = "ok",
      session = session,
      found = !is.null(page) && nzchar(page$text %||% ""),
      text = page$text %||% "",
      references = page$references %||% list()
    ))
  }, error = function(e) {
    .emit_json(.new_error_payload(
      "E_IPC_HELP",
      conditionMessage(e),
      "ipc_help",
      session
    ))
  })
}
