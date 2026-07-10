test_that("help topics parse namespaces and render installed help", {
  parsed <- arkbridge:::.ark_parse_help_topic("base::mean")
  expect_identical(parsed, list(topic = "mean", package = "base"))

  rendered <- arkbridge:::.ark_render_help_text("mean", "base")
  expect_type(rendered, "character")
  expect_true(nzchar(rendered))

  payload <- parse_payload(arkbridge:::.ark_help_text_payload(list(), "base::mean"))
  expect_identical(payload$status, "ok")
  expect_true(payload$found)
  expect_true(nzchar(payload$text))
})

test_that("static targets manifests and networks preserve dependencies", {
  root <- tempfile("arkbridge-targets-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  script <- file.path(root, "_targets.R")
  writeLines(c(
    "tar_target(raw, 1)",
    "tar_target(clean, raw + 1, description = 'clean data')"
  ), script)
  project <- list(root = root, script = script, store = file.path(root, "_targets"))

  manifest <- arkbridge:::.ark_targets_static_manifest(project)
  expect_identical(vapply(manifest, `[[`, character(1), "name"), c("raw", "clean"))
  expect_identical(manifest[[2L]]$description, "clean data")

  network <- arkbridge:::.ark_targets_static_network(project)
  expect_true(any(vapply(network$edges, function(edge) {
    identical(edge$from, "raw") && identical(edge$to, "clean")
  }, logical(1))))

  missing_action <- parse_payload(arkbridge:::.ark_targets_action_payload(list(), root = root))
  expect_identical(missing_action$error$code, "E_IPC_REQUEST")
})

test_that("package helpers normalize names, remotes, and installed metadata", {
  expect_identical(
    arkbridge:::.ark_package_install_names(c(" jsonlite ", "jsonlite", "methods")),
    c("jsonlite", "methods")
  )
  expect_identical(
    arkbridge:::.ark_remote_package_name("owner/example@main")$package,
    "example"
  )

  info <- parse_payload(arkbridge:::.ark_package_info_payload(list(), "base"))
  expect_identical(info$status, "ok")
  expect_true(info$found)
  expect_identical(info$package, "base")

  dry_run <- parse_payload(arkbridge:::.ark_package_install_payload(
    list(), c("jsonlite", "jsonlite"), dry_run = TRUE
  ))
  expect_identical(dry_run$status, "ok")
  expect_identical(dry_run$packages, "jsonlite")
  expect_true(dry_run$dry_run)
})
