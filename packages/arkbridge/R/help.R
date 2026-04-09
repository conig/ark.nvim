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

.ark_help_to_rd <- function(help_page) {
  if (inherits(help_page, "dev_topic")) {
    return(tools::parse_Rd(help_page$path))
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

  chars <- strsplit(enc2utf8(text), "")[[1L]]
  out <- character()

  for (ch in chars) {
    if (identical(ch, "\b")) {
      if (length(out) > 0L) {
        out <- out[-length(out)]
      }
    } else {
      out[[length(out) + 1L]] <- ch
    }
  }

  paste(out, collapse = "")
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
  if (is.null(package)) {
    help_page <- do.call(utils::help, list(
      topic = topic,
      help_type = "text",
      try.all.packages = TRUE
    ))
  } else {
    help_page <- do.call(utils::help, list(
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
