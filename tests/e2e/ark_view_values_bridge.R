for (name in c("utils", "schema", "io", "ipc_service", "view")) {
  source(paste0("packages/arkbridge/R/", name, ".R"))
}
decode <- function(payload) jsonlite::fromJSON(payload, simplifyVector = FALSE)
session <- list(session_id = "values-regression")
opened <- decode(.ark_view_open_object_payload(session, data.table::as.data.table(maps::world.cities), "fixture"))
# The f picker must not serialize every unique value of a high-cardinality column.
started <- proc.time()[[3L]]
first <- decode(.ark_view_values_payload(session, opened$session_id, 1L))
elapsed <- proc.time()[[3L]] - started
cat(sprintf("cold values: %.3fs, %d items\n", elapsed, length(first$values)))
# A generous guardrail (over 7x the measured local cold time) catches returning
# to per-key full-column scans even if the response remains bounded.
stopifnot(elapsed < as.numeric(Sys.getenv("ARK_VIEW_VALUES_BUDGET_SECONDS", unset = "2")))
stopifnot(length(first$values) <= 1000L)
stopifnot(first$total_values == data.table::uniqueN(maps::world.cities$name))
last <- decode(.ark_view_values_payload(session, opened$session_id, 1L, query = "Xianggangdao"))
stopifnot(length(last$values) == 1L, last$values[[1L]]$label == "Xianggangdao")
stopifnot(isTRUE(last$diagnostics$cache_hit), last$diagnostics$rows == nrow(maps::world.cities))
stopifnot(all(c("filter_ms", "keys_ms", "count_ms", "labels_ms", "encode_ms") %in% names(.ark_ipc_state$recent_view_values[[2L]])))
stopifnot(is.numeric(.ark_ipc_state$recent_view_values[[2L]]$response_bytes))
# Sorting must not invalidate value counts; filters on other columns must.
small <- decode(.ark_view_open_object_payload(session,
  data.frame(id = c("a", "b", "a", NA, ""), group = c(1L, 1L, 2L, 2L, 2L)), "small"))
values <- decode(.ark_view_values_payload(session, small$session_id, 1L))
stopifnot(values$total_values == 4L, values$values[[1L]]$count == 2L)
invisible(.ark_view_sort_payload(session, small$session_id, 2L, "desc"))
sorted <- decode(.ark_view_values_payload(session, small$session_id, 1L))
stopifnot(isTRUE(sorted$diagnostics$cache_hit), identical(values$values, sorted$values))
invisible(.ark_view_filter_payload(session, small$session_id, 2L, "1", "exact", .ark_view_value_key(1L), "1"))
filtered <- decode(.ark_view_values_payload(session, small$session_id, 1L))
stopifnot(!filtered$diagnostics$cache_hit, filtered$total_values == 2L)
# A column's own filter is excluded, and changing it does not rebuild its index.
invisible(.ark_view_filter_payload(session, small$session_id, 1L, "a", "exact", .ark_view_value_key("a"), "a"))
self <- decode(.ark_view_values_payload(session, small$session_id, 1L))
stopifnot(isTRUE(self$diagnostics$cache_hit), identical(self$values, filtered$values))
# Optimized key/label generation must preserve the existing exact-value encoding.
fixtures <- list(
  c("", " ", "a  b", "a b", "\\", "\t", "\n", "trn", "é", NA, "a b"),
  c(1L, 2L, NA_integer_, 1L), c(1.2, Inf, -Inf, NaN, NA_real_, 1.2),
  factor(c("b", "a", NA, "b")), as.Date(c("2020-01-01", NA, "2020-01-01")),
  I(list(NULL, 1L, "a", c(1L, 2L), NA_character_))
)
for (column in fixtures) {
  frame <- data.frame(row = seq_along(column))
  frame$value <- column
  opened <- decode(.ark_view_open_object_payload(session, frame, "fixture"))
  payload <- decode(.ark_view_values_payload(session, opened$session_id, 2L))
  keys <- vapply(column, .ark_view_value_key, character(1))
  for (item in payload$values) {
    first <- match(item$value_key, keys)
    stopifnot(!is.na(first), item$count == sum(keys == item$value_key),
      identical(item$label, .ark_view_value_label(column[[first]])))
  }
  stopifnot(length(payload$values) == length(unique(keys)))
}
stopifnot(length(.ark_ipc_state$recent_view_values) <= 16L)
# data.table may mutate an existing object by reference. Explicit refresh must
# invalidate the cached value index, without hashing/scanning data on every f.
dt <- data.table::data.table(name = c("a", "b"))
opened <- decode(.ark_view_open_object_payload(session, dt, "mutable"))
invisible(.ark_view_values_payload(session, opened$session_id, 1L))
data.table::set(dt, j = "name", value = c("new", "new"))
invisible(.ark_view_state_payload(session, opened$session_id))
refreshed <- decode(.ark_view_values_payload(session, opened$session_id, 1L))
stopifnot(!refreshed$diagnostics$cache_hit, refreshed$total_values == 1L,
  refreshed$values[[1L]]$label == "new", refreshed$values[[1L]]$count == 2L)
# Display truncation must not make values outside the first response unfindable.
long_names <- paste0(strrep("prefix", 15L), "-suffix", seq_len(1200L))
opened <- decode(.ark_view_open_object_payload(session, data.frame(name = long_names), "long_names"))
found <- decode(.ark_view_values_payload(session, opened$session_id, 1L, query = "suffix1200"))
stopifnot(length(found$values) == 1L, found$values[[1L]]$value_key == .ark_view_value_key(long_names[[1200L]]))
# Healthy readiness probes must not repeatedly serialize the diagnostic history.
source("packages/arkbridge/R/session_meta.R")
.ark_ipc_state$session <- session
ping <- .emit_json(list(command = "ping", request_id = "probe-test"))
encode <- .emit_json
encoded <- 0L
.emit_json <- function(payload) { encoded <<- encoded + 1L; encode(payload) }
responses <- lapply(seq_len(10L), function(unused) .ark_handle_ipc_request(ping))
stopifnot(encoded == 1L, length(unique(responses)) == 1L)
invisible(.ark_view_values_payload(session, opened$session_id, 1L, query = "suffix1200"))
encoded <- 0L
fresh <- decode(.ark_handle_ipc_request(ping))
stopifnot(encoded == 1L, tail(fresh$recent_view_values, 1L)[[1L]]$returned == 1L)
.emit_json <- encode
# A cached health response must never bypass authentication.
.ark_ipc_state$auth_token <- "fake-test-token"
denied <- decode(.ark_handle_ipc_request(ping))
stopifnot(denied$error$code == "E_IPC_AUTH")
.ark_ipc_state$auth_token <- ""
cat("PASS values, cache/refresh, full search, timings, cached/authenticated pings and display/key semantics\n")
