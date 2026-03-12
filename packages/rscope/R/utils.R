`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

.is_syntactic_name <- function(x) {
  is.character(x) && length(x) == 1L && make.names(x) == x && !grepl("^[0-9]", x)
}

.escape_json_path <- function(path) {
  gsub("\\\\", "\\\\\\\\", path, fixed = TRUE)
}
