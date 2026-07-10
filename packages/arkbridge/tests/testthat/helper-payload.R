parse_payload <- function(payload) {
  jsonlite::fromJSON(payload, simplifyVector = FALSE)
}

with_clean_ipc_state <- function(code) {
  state <- get(".ark_ipc_state", envir = asNamespace("arkbridge"))
  old_token <- state$auth_token
  old_session <- state$session
  old_views <- as.list(state$views, all.names = TRUE)

  on.exit({
    rm(list = ls(state$views, all.names = TRUE), envir = state$views)
    if (length(old_views)) {
      list2env(old_views, envir = state$views)
    }
    state$auth_token <- old_token
    state$session <- old_session
  }, add = TRUE)

  rm(list = ls(state$views, all.names = TRUE), envir = state$views)
  state$auth_token <- ""
  state$session <- list(session_id = "test-session", backend = "tmux")
  force(code)
}
