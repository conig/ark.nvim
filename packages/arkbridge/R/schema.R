.rscope_schema_version <- function() {
  "v1"
}

.new_error_payload <- function(code, message, stage, session) {
  list(
    schema_version = .rscope_schema_version(),
    error = list(
      code = as.character(code),
      message = as.character(message),
      stage = as.character(stage)
    ),
    session = session
  )
}
