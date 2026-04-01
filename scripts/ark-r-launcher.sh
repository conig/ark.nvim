#!/usr/bin/env sh
set -eu

PKG_PATH=""
R_BIN="${ARK_NVIM_R_BIN:-${RSCOPE_R_BIN:-R}}"
BOOTSTRAP_LIB="${ARK_NVIM_SESSION_LIB:-${RSCOPE_R_LIB:-}}"
R_ARGS="${ARK_NVIM_R_ARGS:-${RSCOPE_R_ARGS:---quiet --no-save}}"
STATUS_DIR="${ARK_STATUS_DIR:-${RSCOPE_STATUS_DIR:-$HOME/.local/state/nvim/ark-status}}"
IPC_MAX_REQUEST_BYTES="${ARK_IPC_MAX_REQUEST_BYTES:-${RSCOPE_IPC_MAX_REQUEST_BYTES:-65536}}"
IPC_READ_TIMEOUT_MS="${ARK_IPC_READ_TIMEOUT_MS:-${RSCOPE_IPC_READ_TIMEOUT_MS:-250}}"

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
  PKG_PATH="${ARK_NVIM_SESSION_PKG_PATH:-${RSCOPE_PKG_PATH:-$DEFAULT_PKG_PATH}}"
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
PROMPT_WATCH_TIMEOUT_MS="${ARK_PROMPT_WATCH_TIMEOUT_MS:-${RSCOPE_PROMPT_WATCH_TIMEOUT_MS:-10000}}"

encode_status_component() {
  printf '%s' "$1" | perl -CSDA -pe 's/([^A-Za-z0-9._-])/sprintf("%%%02X", ord($1))/ge' | tr -d '\n'
}

STATUS_FILE=""
if [ -n "$STATUS_DIR" ] && [ -n "$TMUX_SOCKET" ] && [ -n "$TMUX_SESSION" ] && [ -n "$TMUX_PANE" ]; then
  STATUS_FILE="$STATUS_DIR/$(encode_status_component "$TMUX_SOCKET")__$(encode_status_component "$TMUX_SESSION")__$(encode_status_component "$TMUX_PANE").json"
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
  if (identical(Sys.getenv("ARK_LAUNCHER_INSTALLING", unset = ""), "1")) {
    return(invisible(NULL))
  }

  .pane <- Sys.getenv("TMUX_PANE", unset = "")
  .socket <- "$TMUX_SOCKET_R"
  .session <- "$TMUX_SESSION_R"
  .status_root <- Sys.getenv("RSCOPE_STATUS_DIR", unset = "$STATUS_DIR_R")
  .ipc_max_request_bytes <- suppressWarnings(as.integer(Sys.getenv(
    "RSCOPE_IPC_MAX_REQUEST_BYTES",
    unset = "$IPC_MAX_REQUEST_BYTES_R"
  )))
  .ipc_read_timeout_ms <- suppressWarnings(as.integer(Sys.getenv(
    "RSCOPE_IPC_READ_TIMEOUT_MS",
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

  .log_file_path <- function() {
    if (!nzchar(.status_root)) {
      return(tempfile("rscope-launcher-log-", fileext = ".log"))
    }

    .log_dir <- file.path(.status_root, "logs")
    dir.create(.log_dir, recursive = TRUE, showWarnings = FALSE)
    suppressWarnings(Sys.chmod(.log_dir, mode = "700", use_umask = FALSE))

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

    if (!length(.parts)) {
      return(tempfile("rscope-launcher-log-", tmpdir = .log_dir, fileext = ".log"))
    }

    file.path(.log_dir, sprintf("%s--%d.log", paste(.parts, collapse = "__"), as.integer(Sys.getpid())))
  }

  .quiet_log <- .log_file_path()
  .quiet_con <- file(.quiet_log, open = "wt")
  .launcher_started_at <- Sys.time()
  .repl_seq <- 0L

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

    .name <- paste(
      .encode_component(.socket),
      .encode_component(.session),
      .encode_component(.pane),
      sep = "__"
    )
    file.path(.status_root, paste0(.name, ".json"))
  }

  .write_status <- function(status, fields = list()) {
    .path <- .status_file_path()
    if (!nzchar(.path)) {
      return(invisible(NULL))
    }

    .dir <- dirname(.path)
    dir.create(.dir, recursive = TRUE, showWarnings = FALSE)
    suppressWarnings(Sys.chmod(.dir, mode = "700", use_umask = FALSE))

    .payload <- utils::modifyList(
      list(
        status = as.character(status),
        ts = as.integer(Sys.time()),
        ts_iso = .timestamp_iso(),
        pid = as.integer(Sys.getpid()),
        log_path = normalizePath(.quiet_log, winslash = "/", mustWork = FALSE),
        elapsed_ms = .elapsed_ms(),
        repl_ready = FALSE,
        repl_ts = NULL
      ),
      fields
    )

    .json <- jsonlite::toJSON(
      .payload,
      auto_unbox = TRUE,
      null = "null",
      pretty = FALSE
    )

    .tmp <- tempfile("rscope-status-", tmpdir = .dir, fileext = ".json")
    writeLines(.json, .tmp, useBytes = TRUE)
    suppressWarnings(Sys.chmod(.tmp, mode = "600", use_umask = FALSE))
    if (!isTRUE(file.rename(.tmp, .path))) {
      writeLines(.json, .path, useBytes = TRUE)
      unlink(.tmp)
    }
    suppressWarnings(Sys.chmod(.path, mode = "600", use_umask = FALSE))

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

  .write_ready_status <- function(port, auth_token) {
    .write_status("ready", list(
      port = as.integer(port),
      auth_token = auth_token,
      repl_ready = TRUE,
      repl_ts = as.integer(Sys.time()),
      repl_seq = .repl_seq
    ))
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

  if (!interactive()) {
    return(invisible(NULL))
  }

  .has_runtime <- function() {
    if (!requireNamespace("arkbridge", quietly = TRUE)) return(FALSE)
    .ns <- asNamespace("arkbridge")
    exists("start_ipc_service", envir = .ns, inherits = FALSE) &&
      exists(".rscope_dispatch_ipc_request", envir = .ns, inherits = FALSE) &&
      exists(".rscope_resolve_eval_env", envir = .ns, inherits = FALSE)
  }

  .new_auth_token <- function() {
    .bytes <- suppressWarnings(as.integer(stats::runif(32L, min = 0, max = 256)))
    .bytes[is.na(.bytes)] <- 0L
    paste(sprintf("%02x", .bytes %% 256L), collapse = "")
  }

  .install_check_key <- function(pkg_path, lib_path) {
    paste0(
      normalizePath(pkg_path, winslash = "/", mustWork = FALSE),
      "::",
      normalizePath(lib_path, winslash = "/", mustWork = FALSE)
    )
  }

  .install_check_done <- function(key) {
    .cache <- getOption("rscope.install_check_cache")
    if (!is.list(.cache)) return(FALSE)
    isTRUE(.cache[[key]])
  }

  .mark_install_check_done <- function(key) {
    .cache <- getOption("rscope.install_check_cache")
    if (!is.list(.cache)) .cache <- list()
    .cache[[key]] <- TRUE
    options(rscope.install_check_cache = .cache)
  }

  .latest_mtime <- function(paths) {
    .paths <- unique(paths[file.exists(paths)])
    if (!length(.paths)) return(as.POSIXct(0, origin = "1970-01-01", tz = "UTC"))
    .vals <- file.info(.paths)\$mtime
    .vals <- .vals[!is.na(.vals)]
    if (!length(.vals)) return(as.POSIXct(0, origin = "1970-01-01", tz = "UTC"))
    max(.vals)
  }

  .stale_lock_seconds <- suppressWarnings(as.numeric(Sys.getenv(
    "ARK_INSTALL_STALE_LOCK_SECONDS",
    unset = "600"
  )))
  if (!is.finite(.stale_lock_seconds) || .stale_lock_seconds <= 0) {
    .stale_lock_seconds <- 600
  }

  .install_lock_dir <- function(lib_path, pkg_name = "arkbridge") {
    if (!nzchar(lib_path)) return("")
    file.path(lib_path, paste0("00LOCK-", pkg_name))
  }

  .cleanup_stale_install_lock <- function(lib_path, pkg_name = "arkbridge", stale_seconds = 600) {
    .lock_dir <- .install_lock_dir(lib_path, pkg_name)
    if (!nzchar(.lock_dir) || !dir.exists(.lock_dir)) {
      return(FALSE)
    }

    .info <- tryCatch(file.info(.lock_dir), error = function(e) NULL)
    if (is.null(.info) || nrow(.info) == 0L || is.na(.info\$mtime[[1]])) {
      return(FALSE)
    }

    .age_seconds <- as.numeric(difftime(Sys.time(), .info\$mtime[[1]], units = "secs"))
    if (!is.finite(.age_seconds) || .age_seconds < stale_seconds) {
      return(FALSE)
    }

    unlink(.lock_dir, recursive = TRUE, force = TRUE)
    if (dir.exists(.lock_dir)) {
      return(FALSE)
    }

    .write_status("pending", list(
      phase = "stale_lock_cleared",
      lock_dir = .lock_dir,
      lock_age_seconds = as.integer(.age_seconds)
    ))
    TRUE
  }

  .package_source_files <- function(pkg_path) {
    .files <- c(
      file.path(pkg_path, "DESCRIPTION"),
      file.path(pkg_path, "NAMESPACE")
    )

    for (.dir in c("R", "src")) {
      .root <- file.path(pkg_path, .dir)
      if (dir.exists(.root)) {
        .all <- list.files(.root, recursive = TRUE, full.names = TRUE, no.. = TRUE)
        .keep <- grepl("[.](R|r|c|h|cc|cpp|cxx|f|f90|f95|for|m|mm)$", .all)
        .base <- basename(.all)
        .keep <- .keep | .base %in% c("Makevars", "Makevars.win")
        .files <- c(.files, .all[.keep])
      }
    }

    .files
  }

  .current_r_series <- function() {
    .parts <- strsplit(as.character(getRversion()), ".", fixed = TRUE)[[1]]
    if (length(.parts) >= 2L) {
      return(paste(.parts[[1]], .parts[[2]], sep = "."))
    }
    as.character(getRversion())
  }

  .built_matches_current_r <- function(pkg_name = "arkbridge") {
    .desc <- tryCatch(utils::packageDescription(pkg_name), error = function(e) NULL)
    if (is.null(.desc)) return(FALSE)
    .built <- .desc\$Built
    if (!is.character(.built) || !nzchar(.built)) return(FALSE)
    grepl(paste0("^R\\\\s+", .current_r_series(), "([.; ]|$)"), .built)
  }

  .resolve_install_lib <- function(preferred = "") {
    .candidates <- unique(c(preferred, .libPaths()))
    .candidates <- .candidates[nzchar(.candidates)]
    if (!length(.candidates)) {
      return("")
    }

    for (.cand in .candidates) {
      if (!dir.exists(.cand)) {
        suppressWarnings(dir.create(.cand, recursive = TRUE, showWarnings = FALSE))
      }
      if (dir.exists(.cand) && file.access(.cand, mode = 2) == 0) {
        return(.cand)
      }
    }

    ""
  }

  .needs_install <- function(pkg_path) {
    if (!dir.exists(pkg_path)) return(TRUE)
    .desc_path <- file.path(pkg_path, "DESCRIPTION")
    if (!file.exists(.desc_path)) return(TRUE)
    if (!requireNamespace("arkbridge", quietly = TRUE)) return(TRUE)
    if (!.has_runtime()) return(TRUE)

    .installed_path <- tryCatch(find.package("arkbridge"), error = function(e) "")
    if (!nzchar(.installed_path)) return(TRUE)

    .src_dcf <- tryCatch(read.dcf(.desc_path), error = function(e) NULL)
    .src_version <- if (!is.null(.src_dcf) && "Version" %in% colnames(.src_dcf)) as.character(.src_dcf[1, "Version"]) else ""
    .installed_version <- tryCatch(as.character(utils::packageVersion("arkbridge")), error = function(e) "")
    if (nzchar(.src_version) && nzchar(.installed_version) && !identical(.src_version, .installed_version)) {
      return(TRUE)
    }
    if (!.built_matches_current_r("arkbridge")) {
      return(TRUE)
    }

    .src_mtime <- .latest_mtime(.package_source_files(pkg_path))
    .installed_mtime <- .latest_mtime(c(
      file.path(.installed_path, "DESCRIPTION"),
      file.path(.installed_path, "Meta", "package.rds")
    ))
    .delta <- as.numeric(difftime(.src_mtime, .installed_mtime, units = "secs"))
    if (!is.na(.delta) && .delta > 1) return(TRUE)

    FALSE
  }

  tryCatch({
    .write_status("pending", list(phase = "launcher_init"))

    sink(.quiet_con)
    sink(.quiet_con, type = "message")
    on.exit({
      try(sink(type = "message"), silent = TRUE)
      try(sink(), silent = TRUE)
      try(close(.quiet_con), silent = TRUE)
    }, add = TRUE)

    .bootstrap_lib <- Sys.getenv("ARK_R_LIB", unset = "$BOOTSTRAP_LIB_R")
    if (nzchar(.bootstrap_lib)) {
      dir.create(.bootstrap_lib, recursive = TRUE, showWarnings = FALSE)
      .libPaths(unique(c(.bootstrap_lib, .libPaths())))
    }
    .install_lib <- .resolve_install_lib(.bootstrap_lib)
    if (!nzchar(.install_lib)) {
      stop(paste0(
        "E_LIB_NOT_WRITABLE: no writable R library path available (checked: ",
        paste(unique(.libPaths()), collapse = ", "),
        ")"
      ))
    }
    if (nzchar(.bootstrap_lib)) {
      .libPaths(unique(c(.install_lib, .libPaths())))
    }

    .pkg_path <- "$PKG_PATH_R"
    .auth_token <- Sys.getenv("ARK_IPC_AUTH_TOKEN", unset = "")
    if (!nzchar(.auth_token)) {
      .auth_token <- .new_auth_token()
    }
    .cleanup_stale_install_lock(
      lib_path = .install_lib,
      pkg_name = "arkbridge",
      stale_seconds = .stale_lock_seconds
    )
    .check_key <- .install_check_key(.pkg_path, .install_lib)
    .checked <- .install_check_done(.check_key)
    .must_install <- FALSE

    .write_status("pending", list(
      phase = "check_install",
      checked = if (.checked) 1 else 0,
      install_lib = .install_lib
    ))

    if (!.checked) {
      .must_install <- .needs_install(.pkg_path)
    } else if (!.has_runtime()) {
      .must_install <- TRUE
    }

    if (.must_install) {
      .write_status("pending", list(
        phase = "installing",
        updating = 1,
        install_lib = .install_lib
      ))
      if ("arkbridge" %in% loadedNamespaces()) {
        try(unloadNamespace("arkbridge"), silent = TRUE)
      }
      local({
        .old_profile_user <- Sys.getenv("R_PROFILE_USER", unset = NA_character_)
        .old_launcher_installing <- Sys.getenv("ARK_LAUNCHER_INSTALLING", unset = NA_character_)
        on.exit({
          if (is.na(.old_profile_user)) {
            Sys.unsetenv("R_PROFILE_USER")
          } else {
            Sys.setenv(R_PROFILE_USER = .old_profile_user)
          }
          if (is.na(.old_launcher_installing)) {
            Sys.unsetenv("ARK_LAUNCHER_INSTALLING")
          } else {
            Sys.setenv(ARK_LAUNCHER_INSTALLING = .old_launcher_installing)
          }
        }, add = TRUE)

        Sys.setenv(R_PROFILE_USER = "", ARK_LAUNCHER_INSTALLING = "1")
        .install_err <- tryCatch({
          utils::install.packages(.pkg_path, repos = NULL, type = "source", lib = .install_lib, quiet = TRUE)
          NULL
        }, error = function(e) e)
        if (inherits(.install_err, "error")) {
          .lock_dir <- .install_lock_dir(.install_lib, "arkbridge")
          if (nzchar(.lock_dir) && dir.exists(.lock_dir)) {
            stop(paste0(
              "E_INSTALL_LOCK: ",
              conditionMessage(.install_err),
              " (install lock present at '",
              .lock_dir,
              "')"
            ))
          }
          stop(paste0("E_INSTALL_FAILED: ", conditionMessage(.install_err)))
        }
      })
      .write_status("pending", list(
        phase = "install_done",
        updating = 0,
        install_lib = .install_lib
      ))
    } else {
      .write_status("pending", list(
        phase = "up_to_date",
        updating = 0,
        install_lib = .install_lib
      ))
    }

    if (!.checked) {
      .mark_install_check_done(.check_key)
    }

    if ("arkbridge" %in% loadedNamespaces()) {
      try(unloadNamespace("arkbridge"), silent = TRUE)
    }

    if (.has_runtime()) {
      .pane_id <- suppressWarnings(as.integer(gsub("[^0-9]", "", .pane)))
      if (is.na(.pane_id)) {
        .pane_id <- as.integer(Sys.getpid() %% 1000L)
      }
      .port <- as.integer(43000L + (.pane_id %% 1000L))
      .write_status("pending", list(
        phase = "start_service",
        updating = 0,
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

      .write_ready_status(.svc\$port, .auth_token)
      addTaskCallback(function(expr, value, ok, visible) {
        .repl_seq <<- .repl_seq + 1L
        try(.write_ready_status(.svc\$port, .auth_token), silent = TRUE)
        TRUE
      })
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

if [ -n "$STATUS_FILE" ] && [ -n "$TMUX_SOCKET" ] && [ -n "$TMUX_PANE" ] && [ -x "$SCRIPT_DIR/ark-wait-for-repl.sh" ]; then
  "$SCRIPT_DIR/ark-wait-for-repl.sh" \
    --socket "$TMUX_SOCKET" \
    --pane "$TMUX_PANE" \
    --status-file "$STATUS_FILE" \
    --timeout-ms "$PROMPT_WATCH_TIMEOUT_MS" \
    >/dev/null 2>&1 &
fi

ARK_STATUS_DIR="$STATUS_DIR" \
ARK_IPC_MAX_REQUEST_BYTES="$IPC_MAX_REQUEST_BYTES" \
ARK_IPC_READ_TIMEOUT_MS="$IPC_READ_TIMEOUT_MS" \
ARK_ORIG_R_PROFILE_USER="${R_PROFILE_USER:-}" \
ARK_R_LIB="$BOOTSTRAP_LIB" \
RSCOPE_STATUS_DIR="$STATUS_DIR" \
RSCOPE_IPC_MAX_REQUEST_BYTES="$IPC_MAX_REQUEST_BYTES" \
RSCOPE_IPC_READ_TIMEOUT_MS="$IPC_READ_TIMEOUT_MS" \
R_PROFILE_USER="$PROFILE_FILE" \
"$R_BIN" $R_ARGS
