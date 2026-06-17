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

if (!requireNamespace("targets", quietly = TRUE)) {
  fail("targets package is required for targets bridge crew test")
}
if (!requireNamespace("crew", quietly = TRUE)) {
  fail("crew package is required for targets bridge crew test")
}

root <- tempfile("ark-targets-bridge-crew-")
dir.create(root, recursive = TRUE)
script <- file.path(root, "_targets.R")
store <- file.path(root, "_targets")

writeLines(c(
  "library(targets)",
  "library(crew)",
  "bridge_pid <- Sys.getpid()",
  "tar_option_set(",
  "  controller = crew_controller_local(name = 'ark_repro', workers = 1),",
  "  storage = 'worker',",
  "  retrieval = 'worker'",
  ")",
  "list(",
  "  targets::tar_target(cleaned_data, {",
  "    if (Sys.getpid() != bridge_pid) {",
  "      stop('target escaped managed R session', call. = FALSE)",
  "    }",
  "    'ok'",
  "  })",
  ")"
), script)

session <- list(id = "ark-targets-crew-test")

# Regression: Ark target actions are sent through the live session bridge. Even
# when a project configures crew, the bridge must not let tar_make() escape into
# a separate worker process because that no longer behaves like the managed R
# session used by the Neovim command.
payload <- decode_payload(.ark_targets_action_payload(session, "make", root, script, store, list("cleaned_data")))

expect_true(identical(payload$status, "ok"), paste("make action should stay in the bridge process:", payload$error$message %||% ""))
expect_true(identical(payload$result$completed, TRUE), "make action should complete")
