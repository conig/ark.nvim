test_that("schema and error payloads preserve machine-readable context", {
  payload <- arkbridge:::.new_error_payload(
    "E_TEST",
    "test failure",
    "test_stage",
    list(session_id = "session-1")
  )

  expect_identical(payload$schema_version, "v1")
  expect_identical(payload$error$code, "E_TEST")
  expect_identical(payload$error$stage, "test_stage")
  expect_identical(payload$session$session_id, "session-1")
})

test_that("IPC dispatch validates decode, identity, and auth before commands", {
  with_clean_ipc_state({
    decoded <- parse_payload(arkbridge:::.ark_handle_ipc_request("not-json"))
    expect_identical(decoded$error$code, "E_IPC_DECODE")

    missing_id <- parse_payload(arkbridge:::.ark_handle_ipc_request('{"command":"ping"}'))
    expect_identical(missing_id$error$code, "E_IPC_REQUEST")

    state <- get(".ark_ipc_state", envir = asNamespace("arkbridge"))
    state$auth_token <- "secret"
    unauthorized <- parse_payload(arkbridge:::.ark_handle_ipc_request(
      '{"request_id":"request-1","command":"ping","auth_token":"wrong"}'
    ))
    expect_identical(unauthorized$error$code, "E_IPC_AUTH")

    ping <- parse_payload(arkbridge:::.ark_handle_ipc_request(
      '{"request_id":"request-2","command":"ping","auth_token":"secret"}'
    ))
    expect_identical(ping$status, "ok")
    expect_identical(ping$schema_version, "v1")
    expect_identical(ping$session$session_id, "test-session")
  })
})

test_that("namespace completion can request all members without changing inspect defaults", {
  object <- stats::setNames(vector("list", 300L), sprintf("internal_%03d", seq_len(300L)))
  options <- list(request_profile = "completion_lean")
  expect_length(arkbridge::inspect_object(object, options)$members, 200L)

  options$max_members <- 0L
  members <- arkbridge::inspect_object(object, options)$members
  expect_identical(vapply(members, `[[`, character(1), "name_raw"), names(object))

  options$member_name_prefix <- "internal_29"
  members <- arkbridge::inspect_object(object, options)$members
  expect_length(members, 10L)
})

test_that("runtime identity describes loaded code, not a replacement installation", {
  identity <- arkbridge:::.ark_loaded_identity
  previous <- identity$value
  on.exit(identity$value <- previous, add = TRUE)
  library <- tempfile()
  dir.create(file.path(library, "arkbridge"), recursive = TRUE)
  on.exit(unlink(library, recursive = TRUE), add = TRUE)
  stamp <- file.path(library, "arkbridge", "ark-install-identity.json")
  writeLines('{"source_fingerprint":"old"}', stamp)
  arkbridge:::.onLoad(library, "arkbridge")
  writeLines('{"source_fingerprint":"new"}', stamp)
  expect_identical(arkbridge:::.ark_runtime_identity()$source_fingerprint, "old")
})
