.emit_json <- function(x) {
  jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", pretty = FALSE, force = TRUE)
}

write_emit_menu <- function(expr, out_file, options = list()) {
  payload <- emit_menu(expr, options = options)
  cat(payload, file = out_file)
  invisible(out_file)
}

emit_menu_from_base64 <- function(expr_b64, options = list()) {
  raw <- jsonlite::base64_dec(expr_b64)
  expr <- rawToChar(raw)
  emit_menu(expr, options = options)
}

request_from_base64 <- function(expr_b64, out_file, session = list(), options = list()) {
  options <- options %||% list()
  options$session <- session %||% list()
  payload <- emit_menu_from_base64(expr_b64, options = options)
  cat(payload, file = out_file)
  invisible(out_file)
}
