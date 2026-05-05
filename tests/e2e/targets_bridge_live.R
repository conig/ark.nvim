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
  "targets::tar_config_set(store = 'cache/targets')",
  "list(",
  "  targets::tar_target(raw_data, data.frame(id = 1:3, value = c('a', 'b', 'c'))),",
  "  targets::tar_target(clean_data, raw_data),",
  "  targets::tar_target(dt_data, data.table::data.table(dt_id = 1:3, dt_value = c('x', 'y', 'z'))),",
  "  targets::tar_target(list_data, list(alpha = 1, beta = 'two')),",
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
expect_names(manifest$targets, c("raw_data", "clean_data", "dt_data", "list_data", "report"))

network <- decode_payload(.ark_targets_network_payload(session, root, script, store))
expect_true(identical(network$status, "ok"), "network should be ok")
edges <- network$edges %||% list()
edge_labels <- vapply(edges, function(edge) paste(edge$from %||% "", edge$to %||% "", sep = "->"), character(1))
expect_true("raw_data->clean_data" %in% edge_labels, "network should include raw_data -> clean_data")
expect_true("clean_data->report" %in% edge_labels, "network should include clean_data -> report")

make <- decode_payload(.ark_targets_action_payload(session, "make", root, script, store, list("clean_data", "dt_data", "list_data")))
expect_true(identical(make$status, "ok"), "make action should be ok")

old <- setwd(root)
completion_values <- tryCatch(
  list(
    data_frame = .ark_targets_read_for_completion("clean_data"),
    data_table = .ark_targets_read_for_completion("dt_data"),
    list_data = .ark_targets_read_for_completion("list_data")
  ),
  finally = setwd(old)
)
expect_true(is.data.frame(completion_values$data_frame), "completion target reader should return a data frame")
expect_true(identical(names(completion_values$data_frame), c("id", "value")), "completion target reader should preserve data frame columns")
expect_true(inherits(completion_values$data_table, "data.table"), "completion target reader should return a data.table")
expect_true(identical(names(completion_values$data_table), c("dt_id", "dt_value")), "completion target reader should preserve data.table columns")
expect_true(is.list(completion_values$list_data), "completion target reader should return a list")
expect_true(identical(names(completion_values$list_data), c("alpha", "beta")), "completion target reader should preserve list members")

meta <- decode_payload(.ark_targets_meta_payload(session, root, script, store, list("clean_data", "dt_data", "list_data")))
expect_true(identical(meta$status, "ok"), "metadata should be ok")
expect_true(length(meta$meta) >= 3L, "metadata should include requested targets")

object <- decode_payload(.ark_targets_object_meta_payload(session, root, script, store, "clean_data"))
expect_true(identical(object$status, "ok"), "object metadata should be ok")
classes <- object$object_meta$object_meta$class %||% character()
expect_true("data.frame" %in% classes, "object metadata should report data.frame class")

dt_object <- decode_payload(.ark_targets_object_meta_payload(session, root, script, store, "dt_data"))
expect_true(identical(dt_object$status, "ok"), "data.table object metadata should be ok")
dt_classes <- dt_object$object_meta$object_meta$class %||% character()
expect_true("data.table" %in% dt_classes, "object metadata should report data.table class")

list_object <- decode_payload(.ark_targets_object_meta_payload(session, root, script, store, "list_data"))
expect_true(identical(list_object$status, "ok"), "list object metadata should be ok")
list_classes <- list_object$object_meta$object_meta$class %||% character()
expect_true("list" %in% list_classes || identical(list_object$object_meta$object_meta$type, "list"), "object metadata should report list object shape")

load <- decode_payload(.ark_targets_action_payload(session, "load", root, script, store, list("clean_data")))
expect_true(identical(load$status, "ok"), "load action should be ok")

downstream <- decode_payload(.ark_targets_action_payload(session, "make_downstream", root, script, store, list("raw_data")))
expect_true(identical(downstream$status, "ok"), "downstream make action should be ok")

invalidate <- decode_payload(.ark_targets_action_payload(session, "invalidate", root, script, store, list("report")))
expect_true(identical(invalidate$status, "ok"), "invalidate action should be ok")
