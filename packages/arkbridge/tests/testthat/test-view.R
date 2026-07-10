test_that("view sessions filter and page rectangular data", {
  with_clean_ipc_state({
    fixture <- new.env(parent = emptyenv())
    fixture$rows <- data.frame(
      id = 1:4,
      label = c("alpha", "beta", "alphabet", "gamma"),
      stringsAsFactors = FALSE
    )

    opened <- parse_payload(arkbridge:::.ark_view_open_payload(
      list(session_id = "session-1"),
      "rows",
      list(envir = fixture)
    ))
    expect_identical(opened$status, "ok")
    expect_identical(opened$total_rows, 4L)

    filtered <- parse_payload(arkbridge:::.ark_view_filter_payload(
      list(session_id = "session-1"),
      opened$session_id,
      2L,
      "alpha"
    ))
    expect_identical(filtered$total_rows, 2L)

    page <- parse_payload(arkbridge:::.ark_view_page_payload(
      list(session_id = "session-1"),
      opened$session_id,
      offset = 1L,
      limit = 1L
    ))
    expect_identical(page$total_rows, 2L)
    expect_identical(page$row_numbers, list(2L))
    expect_length(page$rows, 1L)

    closed <- parse_payload(arkbridge:::.ark_view_close_payload(
      list(session_id = "session-1"),
      opened$session_id
    ))
    expect_identical(closed$status, "ok")

    gone <- parse_payload(arkbridge:::.ark_view_state_payload(
      list(session_id = "session-1"),
      opened$session_id
    ))
    expect_identical(gone$error$code, "E_IPC_VIEW_GONE")
  })
})

test_that("view filters reject invalid comparison contracts", {
  expect_error(
    arkbridge:::.ark_view_parse_filter(letters, "10", mode = "gt"),
    class = "ark_view_error"
  )
})
