source("packages/arkbridge/R/utils.R")
source("packages/arkbridge/R/schema.R")
source("packages/arkbridge/R/io.R")
source("packages/arkbridge/R/package_install.R")

decode_payload <- function(payload) {
  jsonlite::fromJSON(payload, simplifyVector = FALSE)
}

tempdir <- tempfile("ark-package-install-")
dir.create(tempdir, recursive = TRUE)
on.exit(unlink(tempdir, recursive = TRUE), add = TRUE)

description <- file.path(tempdir, "DESCRIPTION")
writeLines(c(
  "Package: arkpkgtest",
  "Version: 0.0.1",
  "Imports:",
  "    corx,",
  "    glue,",
  "    pkgdepends,",
  "    custompkg",
  "Remotes:",
  "    jamesconigrave/corx,",
  "    github::r-lib/pkgdepends,",
  "    custompkg = posit-dev/ark"
), description)

specs <- .ark_package_install_specs(
  c("glue", "corx", "custompkg", "pkgdepends"),
  description
)

expected_specs <- c(
  "glue",
  "jamesconigrave/corx",
  "posit-dev/ark",
  "github::r-lib/pkgdepends"
)

if (!identical(unname(specs), expected_specs)) {
  stop("unexpected package specs: ", paste(specs, collapse = ", "), call. = FALSE)
}

dir_specs <- .ark_package_install_specs(c("custompkg"), tempdir)
if (!identical(unname(dir_specs), "posit-dev/ark")) {
  stop("directory DESCRIPTION lookup did not resolve custompkg remote", call. = FALSE)
}

payload <- decode_payload(.ark_package_install_payload(
  session = list(),
  packages = list("custompkg", "glue"),
  description = description,
  dry_run = TRUE
))

if (!identical(payload$status, "ok")) {
  stop("expected dry-run payload status ok: ", paste(capture.output(str(payload)), collapse = "\n"), call. = FALSE)
}

if (!isTRUE(payload$dry_run)) {
  stop("expected dry-run payload", call. = FALSE)
}

if (!identical(unlist(payload$packages, use.names = FALSE), c("custompkg", "glue"))) {
  stop("unexpected payload packages", call. = FALSE)
}

if (!identical(unlist(payload$specs, use.names = FALSE), c("posit-dev/ark", "glue"))) {
  stop("unexpected payload specs", call. = FALSE)
}

if (!identical(payload$description, normalizePath(description, winslash = "/", mustWork = TRUE))) {
  stop("unexpected payload DESCRIPTION path", call. = FALSE)
}

if (!payload$method %in% c("pak", "utils")) {
  stop("unexpected package install method: ", payload$method, call. = FALSE)
}
