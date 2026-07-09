source("packages/arkbridge/R/utils.R")
source("packages/arkbridge/R/schema.R")
source("packages/arkbridge/R/io.R")
source("packages/arkbridge/R/ipc_service.R")
source("packages/arkbridge/R/view.R")

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

schema_names <- function(payload) {
  vapply(payload$schema, function(item) item$name %||% "", character(1))
}

session <- list(session_id = "ark-view-object-bridge")

named_vector <- decode_payload(.ark_view_open_object_payload(session, c(alpha = 1, beta = 2), "named_vector"))
expect_true(identical(named_vector$status, "ok"), "named vector view should be ok")
expect_true(identical(named_vector$kind, "table"), "named vector should open as a table adapter")
expect_true(identical(schema_names(named_vector), c("name", "value")), "named vector should preserve names as a column")

named_vector_page <- decode_payload(.ark_view_page_payload(session, named_vector$session_id, 0, 0))
expect_true(identical(named_vector_page$rows[[1]][[1]], "alpha"), "named vector first name should be visible")
expect_true(identical(named_vector_page$rows[[1]][[2]], "1"), "named vector first value should be visible")

table_view <- decode_payload(.ark_view_open_object_payload(session, table(c("a", "b", "a")), "counts"))
expect_true(identical(table_view$status, "ok"), "table object view should be ok")
expect_true(identical(table_view$kind, "table"), "table object should open through table adapter")
expect_true(identical(schema_names(table_view), c("Var1", "Freq")), "table object should use as.data.frame.table shape")

array_view <- decode_payload(.ark_view_open_object_payload(session, array(1:8, dim = c(2, 2, 2)), "arr"))
expect_true(identical(array_view$status, "ok"), "array object view should be ok")
expect_true(identical(array_view$kind, "table"), "array object should open through base as.data.frame adapter")
expect_true(identical(array_view$total_columns, 4L), "array adapter should flatten to base data.frame columns")

object <- list(
  alpha = 1,
  nested = list(
    df = data.frame(id = 1:2, value = c("a", "b"), stringsAsFactors = FALSE)
  )
)
tree <- decode_payload(.ark_view_open_object_payload(session, object, "object"))
expect_true(identical(tree$status, "ok"), "plain list view should be ok")
expect_true(identical(tree$kind, "tree"), "plain list should open as object tree")
expect_true(isTRUE(tree$root$expandable), "plain list root should be expandable")

children <- decode_payload(.ark_object_children_payload(session, tree$session_id, "", 0, 0))
child_names <- vapply(children$children, function(child) child$name %||% "", character(1))
expect_true(identical(child_names, c("alpha", "nested")), "root children should preserve list names")
expect_true(isTRUE(children$children[[2]]$expandable), "nested list child should be expandable")

nested_children <- decode_payload(.ark_object_children_payload(session, tree$session_id, "2", 0, 0))
expect_true(identical(nested_children$children[[1]]$name, "df"), "nested child should include df")
expect_true(isTRUE(nested_children$children[[1]]$viewable_table), "nested data frame should be table-viewable")

detail <- decode_payload(.ark_object_detail_payload(session, tree$session_id, "2/1"))
expect_true(grepl("# data.frame: 2 x 2", detail$text, fixed = TRUE), "nested data frame detail should include tibble-like preview")

table_child <- decode_payload(.ark_object_table_payload(session, tree$session_id, "2/1"))
expect_true(identical(table_child$kind, "table"), "nested data frame should open as regular table view")
expect_true(identical(schema_names(table_child), c("id", "value")), "nested table schema should be preserved")

search <- decode_payload(.ark_object_search_payload(session, tree$session_id, "df"))
expect_true(length(search$matches) == 1L, "object search should find nested df")
expect_true(identical(search$matches[[1]]$node_id, "2/1"), "object search should return nested node id")
