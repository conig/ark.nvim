source("packages/arkbridge/R/utils.R")
source("packages/arkbridge/R/schema.R")
source("packages/arkbridge/R/io.R")
source("packages/arkbridge/R/member_extract.R")
source("packages/arkbridge/R/inspect.R")
source("packages/arkbridge/R/targets.R")

fail <- function(message) {
  stop(message, call. = FALSE)
}

expect_true <- function(value, message) {
  if (!isTRUE(value)) {
    fail(message)
  }
}

decode_payload <- function(payload) {
  jsonlite::fromJSON(payload, simplifyVector = FALSE)
}

calls <- character()

.ark_targets_package_available <- function() {
  TRUE
}

.ark_targets_with_project <- function(project, expr) {
  force(project)
  force(expr)
}

.ark_targets_invalidate <- function(names, store) {
  calls <<- c(calls, "tar_invalidate")
  expect_true(identical(names, "report"), "expected report target to be invalidated")
  expect_true(is.character(store) && nzchar(store), "expected invalidate store")
  invisible(NULL)
}

.ark_targets_call_export <- function(name, args = list()) {
  calls <<- c(calls, name)
  if (identical(name, "tar_meta") || identical(name, "tar_manifest")) {
    Sys.sleep(1)
    return(data.frame(name = "report"))
  }
  invisible(NULL)
}

payload <- decode_payload(.ark_targets_action_payload(
  session = list(id = "invalidate-order"),
  action = "invalidate",
  root = tempfile("ark-targets-order-"),
  script = tempfile("_targets.R"),
  store = tempfile("_targets"),
  names = "report"
))

expect_true(identical(payload$status, "ok"), "invalidate payload should be ok")
expect_true(identical(calls, "tar_invalidate"), paste("expected immediate invalidation, got:", paste(calls, collapse = ", ")))
