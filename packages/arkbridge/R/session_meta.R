.current_session <- function(options = list()) {
  session_opt <- options$session %||% list()

  list(
    tmux_socket = session_opt$tmux_socket %||% Sys.getenv("RSCOPE_TMUX_SOCKET", unset = ""),
    tmux_session = session_opt$tmux_session %||% Sys.getenv("RSCOPE_TMUX_SESSION", unset = ""),
    tmux_pane = session_opt$tmux_pane %||% Sys.getenv("RSCOPE_TMUX_PANE", unset = "")
  )
}
