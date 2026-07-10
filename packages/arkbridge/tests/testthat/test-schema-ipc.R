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
