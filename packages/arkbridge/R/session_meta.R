.current_session <- function(options = list()) {
  session_opt <- options$session %||% list()

  list(
    tmux_socket = session_opt$tmux_socket %||% Sys.getenv("ARK_TMUX_SOCKET", unset = ""),
    tmux_session = session_opt$tmux_session %||% Sys.getenv("ARK_TMUX_SESSION", unset = ""),
    tmux_pane = session_opt$tmux_pane %||% Sys.getenv("ARK_TMUX_PANE", unset = "")
  )
}
