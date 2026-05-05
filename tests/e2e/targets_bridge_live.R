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

expect_names <- function(records, expected) {
  names <- vapply(records, function(record) record$name %||% "", character(1))
  missing <- setdiff(expected, names)
  expect_true(length(missing) == 0L, paste("missing target names:", paste(missing, collapse = ", ")))
}

decode_payload <- function(payload) {
  jsonlite::fromJSON(payload, simplifyVector = FALSE)
}

root <- tempfile("ark-targets-bridge-")
dir.create(root, recursive = TRUE)
script <- file.path(root, "_targets.R")
store <- file.path(root, "cache", "targets")

writeLines(c(
  "list(",
  "  targets::tar_target(raw_data, data.frame(id = 1:3, value = c('a', 'b', 'c'))),",
  "  targets::tar_target(clean_data, raw_data),",
  "  targets::tar_target(report, paste(clean_data$value, collapse = ','))",
  ")"
), script)

session <- list(id = "ark-targets-live-test")

info <- decode_payload(.ark_targets_project_info_payload(session, root, script, store))
expect_true(identical(info$status, "ok"), "project info should be ok")
expect_true(identical(info$project$store, normalizePath(store, winslash = "/", mustWork = FALSE)), "project info should preserve custom store")
expect_true(isTRUE(info$targets_available), "targets package should be available")

manifest <- decode_payload(.ark_targets_manifest_payload(session, root, script, store))
expect_true(identical(manifest$status, "ok"), "manifest should be ok")
expect_names(manifest$targets, c("raw_data", "clean_data", "report"))

network <- decode_payload(.ark_targets_network_payload(session, root, script, store))
expect_true(identical(network$status, "ok"), "network should be ok")
edges <- network$edges %||% list()
edge_labels <- vapply(edges, function(edge) paste(edge$from %||% "", edge$to %||% "", sep = "->"), character(1))
expect_true("raw_data->clean_data" %in% edge_labels, "network should include raw_data -> clean_data")
expect_true("clean_data->report" %in% edge_labels, "network should include clean_data -> report")

make <- decode_payload(.ark_targets_action_payload(session, "make", root, script, store, c("clean_data")))
expect_true(identical(make$status, "ok"), "make action should be ok")

meta <- decode_payload(.ark_targets_meta_payload(session, root, script, store, c("clean_data")))
expect_true(identical(meta$status, "ok"), "metadata should be ok")
expect_true(length(meta$meta) >= 1L, "metadata should include clean_data")

object <- decode_payload(.ark_targets_object_meta_payload(session, root, script, store, "clean_data"))
expect_true(identical(object$status, "ok"), "object metadata should be ok")
classes <- object$object_meta$object_meta$class %||% character()
expect_true("data.frame" %in% classes, "object metadata should report data.frame class")

load <- decode_payload(.ark_targets_action_payload(session, "load", root, script, store, c("clean_data")))
expect_true(identical(load$status, "ok"), "load action should be ok")
