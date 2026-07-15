# Run the tests
test *ARGS:
  cargo nextest run --no-fail-fast {{ARGS}}

# Run the tests in verbose mode
# `--no-capture` forces stdout/stderr to be shown for all tests, not just failing ones,
# and also forces them to be run sequentially so you don't see interleaved live output
test-verbose:
  cargo nextest run --no-capture

# Run the insta tests in update mode
test-insta:
  cargo insta test --test-runner nextest

# Run clippy
clippy:
  cargo clippy -p ark-lsp --all-targets -- -D warnings

# Run the routine Neovim product gate
verify-product *ARGS:
  ./scripts/verify-product.sh {{ARGS}}

# Exercise retained upstream crates without making them part of the product gate
verify-upstream-compat *ARGS:
  cargo test --workspace {{ARGS}}

# Run the full verification suite
verify *ARGS:
  ./scripts/run-full-suite.sh {{ARGS}}

# Run the canonical local performance suite
benchmark *ARGS:
  ./scripts/run-performance-suite.sh {{ARGS}}

# Reformat source files
format:
  cargo +nightly-2025-07-18 fmt --all
