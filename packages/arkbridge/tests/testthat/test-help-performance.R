test_that("rendering help does not repeat utils help lookups for every link", {
  lookups <- 0L
  original <- arkbridge:::.ark_original_help_function()
  testthat::local_mocked_bindings(
    .ark_original_help_function = function() {
      function(...) {
        lookups <<- lookups + 1L
        original(...)
      }
    },
    .package = "arkbridge"
  )
  page <- arkbridge:::.ark_render_help_page("lm", "stats")
  expect_match(page$text, "Fitting Linear Models", fixed = TRUE)
  expect_true(length(page$references) > 5L)
  # One lookup selects the real page. Link qualification must reuse its
  # package alias index rather than rereading that index via help per link.
  expect_equal(lookups, 1L)
  glm <- Filter(function(link) identical(link$topic, "glm"), page$references)
  expect_identical(glm[[1L]]$package, "stats")
})

test_that("indexed help links preserve fallback qualification and ordering", {
  for (topic in c("lm", "mean", "head")) {
    help <- do.call(utils::help, list(topic = topic))
    rd <- utils:::.getHelpFile(help)
    package <- arkbridge:::.ark_help_page_package(help[[1L]])
    expect_identical(
      arkbridge:::.ark_collect_help_links(rd, package),
      arkbridge:::.ark_collect_help_links(rd, package, use_index = FALSE)
    )
  }
})
