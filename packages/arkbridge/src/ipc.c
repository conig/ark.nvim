#include <R.h>
#include <Rinternals.h>
#include <R_ext/eventloop.h>

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static int rscope_server_fd = -1;
static int rscope_server_port = 0;
static InputHandler *rscope_input_handler = NULL;
static SEXP rscope_request_callback = NULL;
static void (*rscope_prev_polled_events)(void) = NULL;
static int rscope_prev_wait_usec = 0;
static int rscope_poll_hook_active = 0;
static size_t rscope_max_request_bytes = 65536;
static int rscope_read_timeout_ms = 250;
static int rscope_last_read_error = 0;

static void rscope_ipc_stop_internal(void);

static char *rscope_strdup_or_default(const char *value, const char *fallback) {
  size_t n;
  char *out;

  if (value != NULL) {
    n = strlen(value);
    out = (char *) malloc(n + 1);
    if (out != NULL) {
      memcpy(out, value, n + 1);
      return out;
    }
  }

  n = strlen(fallback);
  out = (char *) malloc(n + 1);
  if (out == NULL) {
    return NULL;
  }
  memcpy(out, fallback, n + 1);
  return out;
}

static int rscope_set_nonblocking(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags < 0) {
    return -1;
  }

  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void rscope_write_all(int fd, const char *buf, size_t len) {
  size_t offset = 0;

  while (offset < len) {
    ssize_t wrote = write(fd, buf + offset, len - offset);
    if (wrote > 0) {
      offset += (size_t) wrote;
      continue;
    }
    if (wrote < 0 && errno == EINTR) {
      continue;
    }
    break;
  }
}

static char *rscope_read_request(int fd) {
  size_t max_bytes = rscope_max_request_bytes > 0 ? rscope_max_request_bytes : 65536;
  size_t cap = 4096;
  size_t len = 0;
  int too_large = 0;
  char *buf = (char *) malloc(cap);
  rscope_last_read_error = 0;
  if (buf == NULL) {
    rscope_last_read_error = ENOMEM;
    return NULL;
  }

  if (cap > (max_bytes + 1)) {
    cap = max_bytes + 1;
  }

  for (;;) {
    if (len >= max_bytes) {
      too_large = 1;
      break;
    }

    if ((len + 1024) >= cap && cap < (max_bytes + 1)) {
      size_t next_cap = cap * 2;
      if (next_cap > (max_bytes + 1)) {
        next_cap = max_bytes + 1;
      }
      char *next = (char *) realloc(buf, next_cap);
      if (next == NULL) {
        free(buf);
        rscope_last_read_error = ENOMEM;
        return NULL;
      }
      buf = next;
      cap = next_cap;
    }

    ssize_t nread = read(fd, buf + len, cap - len - 1);
    if (nread > 0) {
      char *newline = NULL;
      len += (size_t) nread;
      newline = (char *) memchr(buf, '\n', len);
      if (newline != NULL) {
        len = (size_t) (newline - buf);
        break;
      }
      continue;
    }
    if (nread == 0) {
      break;
    }

    if (errno == EINTR) {
      continue;
    }
    free(buf);
    rscope_last_read_error = errno;
    return NULL;
  }

  if (too_large) {
    free(buf);
    rscope_last_read_error = EMSGSIZE;
    return NULL;
  }

  if (len > 0 && buf[len - 1] == '\r') {
    len -= 1;
  }
  buf[len] = '\0';
  return buf;
}

static char *rscope_call_request_handler(const char *request) {
  SEXP req;
  SEXP call;
  SEXP resp;
  int error = 0;
  const char *value = NULL;
  char *out = NULL;

  if (rscope_request_callback == NULL) {
    return rscope_strdup_or_default(
      "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_HANDLER\",\"message\":\"missing callback\",\"stage\":\"ipc_handler\"},\"session\":{\"backend\":\"\",\"session_id\":\"\",\"tmux_socket\":\"\",\"tmux_session\":\"\",\"tmux_pane\":\"\"}}",
      "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_HANDLER\",\"message\":\"missing callback\",\"stage\":\"ipc_handler\"}}"
    );
  }

  req = PROTECT(Rf_mkString(request == NULL ? "" : request));
  call = PROTECT(Rf_lang2(rscope_request_callback, req));
  resp = PROTECT(R_tryEval(call, R_GlobalEnv, &error));

  if (!error && TYPEOF(resp) == STRSXP && XLENGTH(resp) >= 1 && STRING_ELT(resp, 0) != NA_STRING) {
    value = CHAR(STRING_ELT(resp, 0));
  } else {
    value = "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_HANDLER\",\"message\":\"handler failed\",\"stage\":\"ipc_handler\"},\"session\":{\"backend\":\"\",\"session_id\":\"\",\"tmux_socket\":\"\",\"tmux_session\":\"\",\"tmux_pane\":\"\"}}";
  }

  out = rscope_strdup_or_default(value, "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_HANDLER\",\"message\":\"out of memory\",\"stage\":\"ipc_handler\"}}");
  UNPROTECT(3);
  return out;
}

static void rscope_process_client(int client_fd) {
  int flags;
  struct timeval timeout;
  char *request = NULL;
  char *response = NULL;

  flags = fcntl(client_fd, F_GETFL, 0);
  if (flags >= 0) {
    (void) fcntl(client_fd, F_SETFL, flags & ~O_NONBLOCK);
  }
  timeout.tv_sec = rscope_read_timeout_ms / 1000;
  timeout.tv_usec = (rscope_read_timeout_ms % 1000) * 1000;
  (void) setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

  request = rscope_read_request(client_fd);
  if (request == NULL) {
    if (rscope_last_read_error == EMSGSIZE) {
      response = rscope_strdup_or_default(
        "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_TOO_LARGE\",\"message\":\"request exceeded max size\",\"stage\":\"ipc_read\"},\"session\":{\"backend\":\"\",\"session_id\":\"\",\"tmux_socket\":\"\",\"tmux_session\":\"\",\"tmux_pane\":\"\"}}",
        "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_TOO_LARGE\",\"message\":\"request exceeded max size\",\"stage\":\"ipc_read\"}}"
      );
    } else if (rscope_last_read_error == EAGAIN || rscope_last_read_error == EWOULDBLOCK || rscope_last_read_error == ETIMEDOUT) {
      response = rscope_strdup_or_default(
        "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_TIMEOUT\",\"message\":\"timed out reading request\",\"stage\":\"ipc_read\"},\"session\":{\"backend\":\"\",\"session_id\":\"\",\"tmux_socket\":\"\",\"tmux_session\":\"\",\"tmux_pane\":\"\"}}",
        "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_TIMEOUT\",\"message\":\"timed out reading request\",\"stage\":\"ipc_read\"}}"
      );
    } else {
      response = rscope_strdup_or_default(
        "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_READ\",\"message\":\"failed to read request\",\"stage\":\"ipc_read\"},\"session\":{\"backend\":\"\",\"session_id\":\"\",\"tmux_socket\":\"\",\"tmux_session\":\"\",\"tmux_pane\":\"\"}}",
        "{\"schema_version\":\"v1\",\"error\":{\"code\":\"E_IPC_READ\",\"message\":\"failed to read request\",\"stage\":\"ipc_read\"}}"
      );
    }
  } else {
    response = rscope_call_request_handler(request);
  }

  if (response != NULL) {
    rscope_write_all(client_fd, response, strlen(response));
  }

  if (request != NULL) {
    free(request);
  }
  if (response != NULL) {
    free(response);
  }
}

static void rscope_server_ready(void *data) {
  (void) data;

  for (;;) {
    int client_fd = accept(rscope_server_fd, NULL, NULL);
    if (client_fd < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        break;
      }
      break;
    }

    rscope_process_client(client_fd);
    (void) close(client_fd);
  }
}

static void rscope_poll_hook(void) {
  if (rscope_prev_polled_events != NULL) {
    rscope_prev_polled_events();
  }

  if (rscope_server_fd >= 0) {
    rscope_server_ready(NULL);
  }
}

static void rscope_ipc_stop_internal(void) {
  if (rscope_input_handler != NULL) {
    (void) removeInputHandler(&R_InputHandlers, rscope_input_handler);
    rscope_input_handler = NULL;
  }

  if (rscope_server_fd >= 0) {
    (void) close(rscope_server_fd);
    rscope_server_fd = -1;
  }

  if (rscope_request_callback != NULL) {
    R_ReleaseObject(rscope_request_callback);
    rscope_request_callback = NULL;
  }

  if (rscope_poll_hook_active) {
    R_PolledEvents = rscope_prev_polled_events;
    R_wait_usec = rscope_prev_wait_usec;
    rscope_prev_polled_events = NULL;
    rscope_prev_wait_usec = 0;
    rscope_poll_hook_active = 0;
  }

  rscope_server_port = 0;
}

SEXP C_ark_ipc_start(SEXP port, SEXP callback) {
  int server_fd;
  int port_value;
  int opt = 1;
  struct sockaddr_in addr;

  if (!Rf_isNumeric(port) || XLENGTH(port) < 1) {
    Rf_error("port must be numeric");
  }
  if (!(TYPEOF(callback) == CLOSXP || TYPEOF(callback) == BUILTINSXP || TYPEOF(callback) == SPECIALSXP)) {
    Rf_error("callback must be a function");
  }

  port_value = Rf_asInteger(port);
  if (port_value <= 0 || port_value > 65535) {
    Rf_error("invalid IPC port");
  }

  if (rscope_server_fd >= 0) {
    if (rscope_server_port == port_value) {
      return Rf_ScalarInteger(port_value);
    }
    rscope_ipc_stop_internal();
  }

  server_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (server_fd < 0) {
    Rf_error("failed to create IPC socket");
  }

  if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
    (void) close(server_fd);
    Rf_error("failed to configure IPC socket");
  }

  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short) port_value);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

  if (bind(server_fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
    (void) close(server_fd);
    Rf_error("failed to bind IPC socket");
  }

  if (listen(server_fd, 16) < 0) {
    (void) close(server_fd);
    Rf_error("failed to listen on IPC socket");
  }

  if (rscope_set_nonblocking(server_fd) < 0) {
    (void) close(server_fd);
    Rf_error("failed to set IPC socket non-blocking");
  }

  R_PreserveObject(callback);
  rscope_request_callback = callback;
  rscope_server_fd = server_fd;
  rscope_server_port = port_value;

  if (!rscope_poll_hook_active) {
    rscope_prev_polled_events = R_PolledEvents;
    rscope_prev_wait_usec = R_wait_usec;
    R_PolledEvents = rscope_poll_hook;
    if (R_wait_usec <= 0 || R_wait_usec > 50000) {
      R_wait_usec = 10000;
    }
    rscope_poll_hook_active = 1;
  }

  if (R_InputHandlers != NULL) {
    rscope_input_handler = addInputHandler(R_InputHandlers, server_fd, rscope_server_ready, XActivity);
  }

  return Rf_ScalarInteger(port_value);
}

SEXP C_ark_ipc_config(SEXP max_request_bytes, SEXP read_timeout_ms) {
  int max_bytes;
  int timeout_ms;

  if (!Rf_isNumeric(max_request_bytes) || XLENGTH(max_request_bytes) < 1) {
    Rf_error("max_request_bytes must be numeric");
  }
  if (!Rf_isNumeric(read_timeout_ms) || XLENGTH(read_timeout_ms) < 1) {
    Rf_error("read_timeout_ms must be numeric");
  }

  max_bytes = Rf_asInteger(max_request_bytes);
  timeout_ms = Rf_asInteger(read_timeout_ms);
  if (max_bytes < 1024) {
    max_bytes = 1024;
  }
  if (timeout_ms < 10) {
    timeout_ms = 10;
  }

  rscope_max_request_bytes = (size_t) max_bytes;
  rscope_read_timeout_ms = timeout_ms;

  return Rf_ScalarLogical(1);
}

SEXP C_ark_ipc_stop(void) {
  rscope_ipc_stop_internal();
  return Rf_ScalarLogical(1);
}

SEXP C_ark_ipc_status(void) {
  SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));

  SET_STRING_ELT(names, 0, Rf_mkChar("running"));
  SET_STRING_ELT(names, 1, Rf_mkChar("port"));
  SET_VECTOR_ELT(out, 0, Rf_ScalarLogical(rscope_server_fd >= 0));
  SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(rscope_server_port));
  Rf_setAttrib(out, R_NamesSymbol, names);

  UNPROTECT(2);
  return out;
}

void C_ark_ipc_cleanup(void) {
  rscope_ipc_stop_internal();
}
