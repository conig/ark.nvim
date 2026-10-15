test_that("explicit IPC inspection returns the last uncaught error without replacing it", {
  # A genuine top-level error, not tryCatch(): caught errors do not set .Traceback.
  root <- tempfile("ark-traceback-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  source_file <- file.path(root, "failure.R")
  writeLines(c("outer <- function() inner()", "inner <- function() stop('traceback fixture')"), source_file)
  result_file <- file.path(root, "result.rds")
  input <- file.path(root, "input.R")
  quote_r <- function(x) encodeString(x, quote = '"')
  writeLines(c(
    sprintf(".libPaths(c(%s, .libPaths()))", paste(quote_r(.libPaths()), collapse = ",")),
    "library(arkbridge)",
    sprintf("source(%s, keep.source = TRUE)", quote_r(source_file)),
    "outer()",
    "before <- get0('.Traceback', baseenv()); error_option <- getOption('error')",
    "payload <- arkbridge:::.ark_handle_ipc_request('{\"command\":\"error_traceback\",\"request_id\":\"traceback-test\"}')",
    sprintf("saveRDS(list(payload = payload, preserved = identical(before, get0('.Traceback', baseenv())), option_preserved = identical(error_option, getOption('error'))), %s)", quote_r(result_file)),
    "q('no')"
  ), input)
  system2(file.path(R.home("bin"), "R"), c("--vanilla", "--quiet", "--interactive"),
    stdin = input, stdout = file.path(root, "stdout"), stderr = file.path(root, "stderr"))
  result <- readRDS(result_file)
  payload <- parse_payload(result$payload)
  expect_identical(payload$status, "ok")
  expect_true(payload$available)
  expect_true(result$preserved)
  expect_true(result$option_preserved)
  expect_true(any(vapply(payload$frames, function(frame) grepl("inner", frame$call), logical(1))))
  locations <- Filter(function(frame) !is.null(frame$path), payload$frames)
  expect_true(length(locations) > 0L)
  expect_true(all(vapply(locations, function(frame) identical(frame$path, source_file), logical(1))))
  expect_true(all(vapply(locations, function(frame) frame$line %in% c(1L, 2L), logical(1))))
})

test_that("traceback frames are bounded and never invent source locations", {
  frames <- rep(list(quote(wrapper(value))), 10000L)
  payload <- arkbridge:::.ark_traceback_data(frames)
  expect_length(payload$frames, 128L)
  expect_true(payload$truncated)
  expect_true(all(vapply(payload$frames, function(frame) is.null(frame$path), logical(1))))
  expect_identical(arkbridge:::.ark_traceback_data(NULL)$available, FALSE)
  huge <- list(paste(rep("long call", 10000L), collapse = " "))
  expect_lte(nchar(arkbridge:::.ark_traceback_data(huge)$frames[[1L]]$call), 1001L)
  source <- srcfilecopy("<text>", "x()", isFile = FALSE)
  with_ref <- structure("x()", srcref = srcref(source, c(1L, 1L, 1L, 3L, 1L, 3L)))
  expect_null(arkbridge:::.ark_traceback_data(list(with_ref))$frames[[1L]]$path)
})
