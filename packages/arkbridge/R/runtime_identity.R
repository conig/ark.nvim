# Captured at load time, never reread when an installed package is replaced.
.ark_loaded_identity <- new.env(parent = emptyenv())
.ark_loaded_identity$value <- list()

.onLoad <- function(libname, pkgname) {
  path <- file.path(libname, pkgname, "ark-install-identity.json")
  .ark_loaded_identity$value <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) list()
  )
}

.ark_runtime_identity <- function() {
  .ark_loaded_identity$value
}
