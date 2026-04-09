emit_menu <- function(expr, options = list()) {
  session <- .current_session(options)

  payload <- tryCatch({
    env <- options$envir %||% parent.frame()
    obj <- eval(parse(text = expr), envir = env)
    inspected <- inspect_object(obj, options = options)

    list(
      schema_version = .ark_schema_version(),
      session = session,
      object_meta = inspected$object_meta,
      members = inspected$members
    )
  }, error = function(e) {
    .new_error_payload(
      code = "E_EVAL",
      message = conditionMessage(e),
      stage = "emit_menu",
      session = session
    )
  })

  .emit_json(payload)
}
