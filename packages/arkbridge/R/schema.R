.ark_schema_version <- function() {
  "v1"
}

.ark_product_version <- function() {
  Sys.getenv(
    "ARK_NVIM_PRODUCT_VERSION",
    unset = as.character(utils::packageVersion("arkbridge"))
  )
}

.new_error_payload <- function(code, message, stage, session) {
  list(
    schema_version = .ark_schema_version(),
    product_version = .ark_product_version(),
    error = list(
      code = as.character(code),
      message = as.character(message),
      stage = as.character(stage)
    ),
    session = session
  )
}
