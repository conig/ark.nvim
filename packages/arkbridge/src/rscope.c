#include <R.h>
#include <Rinternals.h>
#include <string.h>

SEXP C_ark_member_names(SEXP obj, SEXP accessor) {
  if (TYPEOF(accessor) != STRSXP || XLENGTH(accessor) < 1) {
    Rf_error("accessor must be character");
  }

  const char *acc = CHAR(STRING_ELT(accessor, 0));

  if (strcmp(acc, "@") == 0) {
    Rf_error("S4 slot extraction not supported by C helper");
  }

  if (TYPEOF(obj) == ENVSXP) {
    Rf_error("environment extraction not supported by C helper");
  }

  SEXP names = PROTECT(Rf_getAttrib(obj, R_NamesSymbol));
  if (names == R_NilValue) {
    UNPROTECT(1);
    return Rf_allocVector(STRSXP, 0);
  }

  if (TYPEOF(names) != STRSXP) {
    UNPROTECT(1);
    Rf_error("names attribute must be character");
  }

  SEXP out = PROTECT(Rf_allocVector(STRSXP, XLENGTH(names)));
  for (R_xlen_t i = 0; i < XLENGTH(names); i++) {
    SET_STRING_ELT(out, i, STRING_ELT(names, i));
  }

  UNPROTECT(2);
  return out;
}
