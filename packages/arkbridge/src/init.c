#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

SEXP C_rscope_member_names(SEXP obj, SEXP accessor);
SEXP C_rscope_ipc_start(SEXP port, SEXP callback);
SEXP C_rscope_ipc_config(SEXP max_request_bytes, SEXP read_timeout_ms);
SEXP C_rscope_ipc_stop(void);
SEXP C_rscope_ipc_status(void);
void C_rscope_ipc_cleanup(void);

static const R_CallMethodDef CallEntries[] = {
  {"C_rscope_member_names", (DL_FUNC) &C_rscope_member_names, 2},
  {"C_rscope_ipc_start", (DL_FUNC) &C_rscope_ipc_start, 2},
  {"C_rscope_ipc_config", (DL_FUNC) &C_rscope_ipc_config, 2},
  {"C_rscope_ipc_stop", (DL_FUNC) &C_rscope_ipc_stop, 0},
  {"C_rscope_ipc_status", (DL_FUNC) &C_rscope_ipc_status, 0},
  {NULL, NULL, 0}
};

void R_init_arkbridge(DllInfo *dll) {
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}

void R_unload_arkbridge(DllInfo *dll) {
  (void) dll;
  C_rscope_ipc_cleanup();
}
