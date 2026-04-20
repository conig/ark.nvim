#!/usr/bin/env sh
set -eu

PKG_PATH=""
R_BIN="${ARK_NVIM_R_BIN:-R}"
BOOTSTRAP_LIB="${ARK_NVIM_SESSION_LIB:-}"
R_ARGS="${ARK_NVIM_R_ARGS:---quiet --no-save}"
STATUS_DIR="${ARK_STATUS_DIR:-$HOME/.local/state/nvim/ark-status}"
IPC_MAX_REQUEST_BYTES="${ARK_IPC_MAX_REQUEST_BYTES:-65536}"
IPC_READ_TIMEOUT_MS="${ARK_IPC_READ_TIMEOUT_MS:-250}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEFAULT_PKG_PATH=$(CDPATH= cd -- "$SCRIPT_DIR/../packages/arkbridge" && pwd)

escape_r_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pkg-path)
      PKG_PATH="$2"
      shift 2
      ;;
    --r-bin)
      R_BIN="$2"
      shift 2
      ;;
    --lib)
      BOOTSTRAP_LIB="$2"
      shift 2
      ;;
    --status-dir)
      STATUS_DIR="$2"
      shift 2
      ;;
    --ipc-max-request-bytes)
      IPC_MAX_REQUEST_BYTES="$2"
      shift 2
      ;;
    --ipc-read-timeout-ms)
      IPC_READ_TIMEOUT_MS="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$PKG_PATH" ]; then
  PKG_PATH="${ARK_NVIM_SESSION_PKG_PATH:-$DEFAULT_PKG_PATH}"
fi

TMUX_SOCKET=""
if [ "${TMUX:-}" != "" ]; then
  TMUX_SOCKET=${TMUX%%,*}
fi

TMUX_SESSION=""
if [ "$TMUX_SOCKET" != "" ] && command -v tmux >/dev/null 2>&1; then
  TMUX_SESSION=$(tmux -S "$TMUX_SOCKET" display-message -p "#{session_name}" 2>/dev/null || true)
fi
TMUX_PANE="${TMUX_PANE:-}"

encode_status_component() {
  printf '%s' "$1" | perl -CSDA -pe 's/([^A-Za-z0-9._-])/sprintf("%%%02X", ord($1))/ge' | tr -d '\n'
}

STATUS_FILE=""
SESSION_ID=""
if [ -n "$TMUX_SOCKET" ] && [ -n "$TMUX_SESSION" ] && [ -n "$TMUX_PANE" ]; then
  SESSION_ID="$(encode_status_component "$TMUX_SOCKET")__$(encode_status_component "$TMUX_SESSION")__$(encode_status_component "$TMUX_PANE")"
fi

if [ -n "$STATUS_DIR" ] && [ -n "$SESSION_ID" ]; then
  STATUS_FILE="$STATUS_DIR/$SESSION_ID.json"
fi

PROFILE_FILE=$(mktemp)
PKG_PATH_R=$(escape_r_string "$PKG_PATH")
BOOTSTRAP_LIB_R=$(escape_r_string "$BOOTSTRAP_LIB")
STATUS_DIR_R=$(escape_r_string "$STATUS_DIR")
TMUX_SOCKET_R=$(escape_r_string "$TMUX_SOCKET")
TMUX_SESSION_R=$(escape_r_string "$TMUX_SESSION")
IPC_MAX_REQUEST_BYTES_R=$(escape_r_string "$IPC_MAX_REQUEST_BYTES")
IPC_READ_TIMEOUT_MS_R=$(escape_r_string "$IPC_READ_TIMEOUT_MS")

cat > "$PROFILE_FILE" <<EOR
local({
  .pane <- Sys.getenv("TMUX_PANE", unset = "")
  .socket <- "$TMUX_SOCKET_R"
  .session <- "$TMUX_SESSION_R"
  .status_root <- Sys.getenv("ARK_STATUS_DIR", unset = "$STATUS_DIR_R")
  .ipc_max_request_bytes <- suppressWarnings(as.integer(Sys.getenv(
    "ARK_IPC_MAX_REQUEST_BYTES",
    unset = "$IPC_MAX_REQUEST_BYTES_R"
  )))
  .ipc_read_timeout_ms <- suppressWarnings(as.integer(Sys.getenv(
    "ARK_IPC_READ_TIMEOUT_MS",
    unset = "$IPC_READ_TIMEOUT_MS_R"
  )))

  .encode_component <- function(x) {
    .raw <- charToRaw(enc2utf8(as.character(x)))
    .out <- character(length(.raw))
    for (.i in seq_along(.raw)) {
      .byte <- as.integer(.raw[[.i]])
      .ch <- rawToChar(as.raw(.byte))
      if (grepl("^[A-Za-z0-9._-]$", .ch)) {
        .out[[.i]] <- .ch
      } else {
        .out[[.i]] <- sprintf("%%%02X", .byte)
      }
    }
    paste(.out, collapse = "")
  }

  .status_parts <- function() {
    .parts <- character()
    if (nzchar(.socket)) {
      .parts <- c(.parts, .encode_component(.socket))
    }
    if (nzchar(.session)) {
      .parts <- c(.parts, .encode_component(.session))
    }
    if (nzchar(.pane)) {
      .parts <- c(.parts, .encode_component(.pane))
    }
    .parts
  }

  .artifact_dir <- function(name) {
    if (!nzchar(.status_root)) {
      return("")
    }

    .dir <- file.path(.status_root, name)
    dir.create(.dir, recursive = TRUE, showWarnings = FALSE)
    suppressWarnings(Sys.chmod(.dir, mode = "700", use_umask = FALSE))
    .dir
  }

  .log_file_path <- function() {
    if (!nzchar(.status_root)) {
      return(tempfile("ark-launcher-log-", fileext = ".log"))
    }

    .log_dir <- .artifact_dir("logs")
    .parts <- .status_parts()

    if (!length(.parts)) {
      return(tempfile("ark-launcher-log-", tmpdir = .log_dir, fileext = ".log"))
    }

    file.path(.log_dir, sprintf("%s--%d.log", paste(.parts, collapse = "__"), as.integer(Sys.getpid())))
  }

  .quiet_log <- .log_file_path()
  .quiet_con <- file(.quiet_log, open = "wt")
  .launcher_started_at <- Sys.time()
  .repl_seq <- 0L
  .bootstrap_cache <- NULL
  .bootstrap_path <- ""

  .timestamp_iso <- function(time = Sys.time()) {
    format(time, "%Y-%m-%dT%H:%M:%OS3%z")
  }

  .elapsed_ms <- function(time = Sys.time()) {
    .delta <- as.numeric(difftime(time, .launcher_started_at, units = "secs"))
    if (!is.finite(.delta)) {
      return(NA_integer_)
    }
    as.integer(round(.delta * 1000))
  }

  .log_line <- function(...) {
    .now <- Sys.time()
    .parts <- unlist(list(...), use.names = FALSE)
    .parts <- .parts[!vapply(.parts, is.null, logical(1))]
    .msg <- paste(as.character(.parts), collapse = "")
    cat(
      "[",
      .timestamp_iso(.now),
      " +",
      .elapsed_ms(.now),
      "ms] ",
      .msg,
      "\n",
      file = .quiet_con,
      sep = ""
    )
    flush(.quiet_con)
    invisible(NULL)
  }

  .string_field <- function(x) {
    if (is.null(x) || length(x) == 0L || is.na(x[[1]])) return("")
    as.character(x[[1]])
  }

  .status_file_path <- function() {
    if (!nzchar(.status_root) || !nzchar(.socket) || !nzchar(.session) || !nzchar(.pane)) {
      return("")
    }

    .name <- paste(.status_parts(), collapse = "__")
    file.path(.status_root, paste0(.name, ".json"))
  }

  .bootstrap_file_path <- function() {
    .bootstrap_dir <- .artifact_dir("bootstrap")
    if (!nzchar(.bootstrap_dir)) {
      return("")
    }

    .parts <- .status_parts()
    if (!length(.parts)) {
      return(tempfile("ark-bootstrap-", tmpdir = .bootstrap_dir, fileext = ".json"))
    }

    file.path(.bootstrap_dir, paste0(paste(.parts, collapse = "__"), ".json"))
  }

  .write_json_file <- function(path, payload, prefix) {
    .dir <- dirname(path)
    dir.create(.dir, recursive = TRUE, showWarnings = FALSE)
    suppressWarnings(Sys.chmod(.dir, mode = "700", use_umask = FALSE))

    .json <- jsonlite::toJSON(
      payload,
      auto_unbox = TRUE,
      null = "null",
      pretty = FALSE
    )

    .tmp <- tempfile(prefix, tmpdir = .dir, fileext = ".json")
    writeLines(.json, .tmp, useBytes = TRUE)
    suppressWarnings(Sys.chmod(.tmp, mode = "600", use_umask = FALSE))
    if (!isTRUE(file.rename(.tmp, path))) {
      writeLines(.json, path, useBytes = TRUE)
      unlink(.tmp)
    }
    suppressWarnings(Sys.chmod(path, mode = "600", use_umask = FALSE))
    invisible(path)
  }

  .write_bootstrap_cache <- function(cache) {
    if (!is.list(cache)) {
      return(invisible(""))
    }

    .path <- .bootstrap_file_path()
    if (!nzchar(.path)) {
      return(invisible(""))
    }

    .payload <- utils::modifyList(cache, list(
      repl_seq = .repl_seq
    ))
    .write_json_file(.path, .payload, "ark-bootstrap-")
    .bootstrap_path <<- normalizePath(.path, winslash = "/", mustWork = FALSE)
    invisible(.bootstrap_path)
  }

  .write_status <- function(status, fields = list()) {
    .path <- .status_file_path()
    if (!nzchar(.path)) {
      return(invisible(NULL))
    }

    .payload <- utils::modifyList(
      list(
        status = as.character(status),
        ts = as.integer(Sys.time()),
        ts_iso = .timestamp_iso(),
        pid = as.integer(Sys.getpid()),
        log_path = normalizePath(.quiet_log, winslash = "/", mustWork = FALSE),
        elapsed_ms = .elapsed_ms(),
        bootstrap_path = if (nzchar(.bootstrap_path)) .bootstrap_path else NULL,
        repl_ready = FALSE,
        repl_ts = NULL
      ),
      fields
    )
    .write_json_file(.path, .payload, "ark-status-")

    .log_line(
      "[status] status=", .payload\$status,
      " phase=", .string_field(.payload\$phase),
      " port=", .string_field(.payload\$port),
      " auth_token=", if (nzchar(.string_field(.payload\$auth_token))) "<set>" else "",
      " repl_ready=", if (isTRUE(.payload\$repl_ready)) "true" else "false",
      " error_code=", .string_field(.payload\$error_code),
      " message=", .string_field(.payload\$message)
    )

    invisible(NULL)
  }

  .write_bridge_ready_status <- function(port, auth_token) {
    .write_status("ready", list(
      port = as.integer(port),
      auth_token = auth_token,
      repl_ready = FALSE,
      repl_ts = NULL,
      repl_seq = .repl_seq
    ))
  }

  .write_repl_ready_status <- function(port, auth_token) {
    .write_status("ready", list(
      port = as.integer(port),
      auth_token = auth_token,
      repl_ready = TRUE,
      repl_ts = as.integer(Sys.time()),
      repl_seq = .repl_seq
    ))
  }

  .collect_bootstrap_cache <- function() {
    .total_start <- Sys.time()
    .search_path_start <- Sys.time()
    envs <- lapply(search(), as.environment)
    search_path_symbols <- unique(unlist(lapply(envs, ls, all.names = TRUE), use.names = FALSE))
    .search_path_symbols_ms <- as.integer(round(as.numeric(difftime(Sys.time(), .search_path_start, units = "secs")) * 1000))

    .library_paths_start <- Sys.time()
    library_paths <- base::.libPaths()
    .library_paths_ms <- as.integer(round(as.numeric(difftime(Sys.time(), .library_paths_start, units = "secs")) * 1000))
    .total_ms <- as.integer(round(as.numeric(difftime(Sys.time(), .total_start, units = "secs")) * 1000))

    list(
      repl_seq = .repl_seq,
      search_path_symbols = as.character(search_path_symbols),
      library_paths = as.character(library_paths),
      total_ms = .total_ms,
      search_path_symbols_ms = .search_path_symbols_ms,
      library_paths_ms = .library_paths_ms
    )
  }

  .user_profile <- Sys.getenv("ARK_ORIG_R_PROFILE_USER", unset = "")
  if (!nzchar(.user_profile)) {
    if (file.exists(".Rprofile")) {
      .user_profile <- ".Rprofile"
    } else {
      .home_profile <- path.expand("~/.Rprofile")
      if (file.exists(.home_profile)) {
        .user_profile <- .home_profile
      }
    }
  }

  if (nzchar(.user_profile) && file.exists(.user_profile)) {
    sys.source(.user_profile, envir = .GlobalEnv, keep.source = FALSE)
  }

  .ensure_default_search_path <- function() {
    .defaults <- getOption("defaultPackages")
    if (!is.character(.defaults) || !length(.defaults) || identical(.defaults, "methods")) {
      .defaults <- c("datasets", "utils", "grDevices", "graphics", "stats", "methods")
    }

    for (.pkg in unique(as.character(.defaults))) {
      if (!nzchar(.pkg)) {
        next
      }

      .search_name <- paste0("package:", .pkg)
      if (.search_name %in% search()) {
        next
      }

      suppressPackageStartupMessages(
        require(.pkg, character.only = TRUE, quietly = TRUE, warn.conflicts = FALSE)
      )
    }
  }

  if (!interactive()) {
    return(invisible(NULL))
  }

  .ensure_default_search_path()

  .has_runtime <- function(lib_path = "") {
    .lib_loc <- if (nzchar(lib_path)) lib_path else NULL
    if (!requireNamespace("arkbridge", quietly = TRUE, lib.loc = .lib_loc)) return(FALSE)
    .ns <- asNamespace("arkbridge")
    exists("start_ipc_service", envir = .ns, inherits = FALSE) &&
      exists(".ark_dispatch_ipc_request", envir = .ns, inherits = FALSE) &&
      exists(".ark_resolve_eval_env", envir = .ns, inherits = FALSE)
  }

  .new_auth_token <- function() {
    .bytes <- suppressWarnings(as.integer(stats::runif(32L, min = 0, max = 256)))
    .bytes[is.na(.bytes)] <- 0L
    paste(sprintf("%02x", .bytes %% 256L), collapse = "")
  }

  tryCatch({
    .write_status("pending", list(phase = "launcher_init"))

    sink(.quiet_con)
    sink(.quiet_con, type = "message")
    on.exit({
      try(sink(type = "message"), silent = TRUE)
      try(sink(), silent = TRUE)
    }, add = TRUE)

    .bootstrap_lib <- Sys.getenv("ARK_R_LIB", unset = "$BOOTSTRAP_LIB_R")
    if (nzchar(.bootstrap_lib)) {
      dir.create(.bootstrap_lib, recursive = TRUE, showWarnings = FALSE)
      .libPaths(unique(c(.bootstrap_lib, .libPaths())))
    }
    .auth_token <- Sys.getenv("ARK_IPC_AUTH_TOKEN", unset = "")
    if (!nzchar(.auth_token)) {
      .auth_token <- .new_auth_token()
    }
    .write_status("pending", list(
      phase = "runtime_check",
      install_lib = .bootstrap_lib
    ))

    if ("arkbridge" %in% loadedNamespaces()) {
      try(unloadNamespace("arkbridge"), silent = TRUE)
    }

    if (!.has_runtime(.bootstrap_lib)) {
      stop(paste0(
        "E_BRIDGE_MISSING: pane-side arkbridge runtime is not installed in configured library path (checked: ",
        paste(unique(.libPaths()), collapse = ", "),
        ")"
      ))
    }

    if (.has_runtime(.bootstrap_lib)) {
      .pane_id <- suppressWarnings(as.integer(gsub("[^0-9]", "", .pane)))
      if (is.na(.pane_id)) {
        .pane_id <- as.integer(Sys.getpid() %% 1000L)
      }
      .port <- as.integer(43000L + (.pane_id %% 1000L))
      .write_status("pending", list(
        phase = "start_service",
        port = .port
      ))

      .svc <- arkbridge:::start_ipc_service(
        port = .port,
        options = list(
          session = list(
            tmux_socket = "$TMUX_SOCKET_R",
            tmux_session = "$TMUX_SESSION_R",
            tmux_pane = .pane
          ),
          auth_token = .auth_token,
          ipc_max_request_bytes = .ipc_max_request_bytes,
          ipc_read_timeout_ms = .ipc_read_timeout_ms
        ),
        force = TRUE
      )

      .bootstrap_cache <- tryCatch(
        .collect_bootstrap_cache(),
        error = function(e) {
          .log_line("[bootstrap] cache generation failed: ", conditionMessage(e))
          NULL
        }
      )
      .write_bootstrap_cache(.bootstrap_cache)
      .write_bridge_ready_status(.svc\$port, .auth_token)
      .user_first <- if (exists(".First", envir = .GlobalEnv, inherits = FALSE)) {
        get(".First", envir = .GlobalEnv, inherits = FALSE)
      } else {
        NULL
      }
      assign(
        ".First",
        local({
          .original_first <- .user_first
          function() {
            if (is.function(.original_first)) {
              .original_first()
            }
            .bootstrap_cache <<- tryCatch(
              .collect_bootstrap_cache(),
              error = function(e) {
                .log_line("[bootstrap] post-startup cache generation failed: ", conditionMessage(e))
                .bootstrap_cache
              }
            )
            .write_bootstrap_cache(.bootstrap_cache)
            .write_repl_ready_status(.svc\$port, .auth_token)
            invisible(NULL)
          }
        }),
        envir = .GlobalEnv
      )
      addTaskCallback(function(expr, value, ok, visible) {
        .repl_seq <<- .repl_seq + 1L
        try(.write_repl_ready_status(.svc\$port, .auth_token), silent = TRUE)
        TRUE
      })
      if (is.list(.bootstrap_cache)) {
        .log_line(
          "[bootstrap] cached startup payload symbols=",
          length(.bootstrap_cache\$search_path_symbols),
          " libpaths=",
          length(.bootstrap_cache\$library_paths),
          " total_ms=",
          .string_field(.bootstrap_cache\$total_ms)
        )
      }
      .log_line("[ready] ipc service started on port ", as.integer(.svc\$port))
      invisible(.svc)
    }
  }, error = function(e) {
    .msg <- conditionMessage(e)
    .code <- NULL
    if (grepl("^E_[A-Z_]+\\\\s*:", .msg)) {
      .code <- sub(":.*$", "", .msg)
      .msg <- sub("^[^:]+:\\\\s*", "", .msg)
    }
    if (is.null(.code) && grepl("Too many open files", .msg, fixed = TRUE)) {
      .code <- "E_RESOURCE_LIMIT"
    }
    if (is.null(.code) && grepl("00LOCK-arkbridge", .msg, fixed = TRUE)) {
      .code <- "E_INSTALL_LOCK"
    }
    .log_line("[error] code=", .string_field(.code), " message=", .msg)
    .write_status("error", list(
      message = .msg,
      error_code = .code
    ))
  })
})
EOR

cleanup() {
  rm -f "$PROFILE_FILE"
}
trap cleanup EXIT INT TERM

ARK_STATUS_DIR="$STATUS_DIR" \
ARK_IPC_MAX_REQUEST_BYTES="$IPC_MAX_REQUEST_BYTES" \
ARK_IPC_READ_TIMEOUT_MS="$IPC_READ_TIMEOUT_MS" \
ARK_ORIG_R_PROFILE_USER="${R_PROFILE_USER:-}" \
ARK_R_LIB="$BOOTSTRAP_LIB" \
ARK_SESSION_BACKEND="tmux" \
ARK_SESSION_ID="$SESSION_ID" \
ARK_TMUX_SOCKET="$TMUX_SOCKET" \
ARK_TMUX_SESSION="$TMUX_SESSION" \
ARK_TMUX_PANE="$TMUX_PANE" \
R_PROFILE_USER="$PROFILE_FILE" \
"$R_BIN" $R_ARGS
