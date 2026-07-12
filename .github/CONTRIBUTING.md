# Contributing to ark.nvim

ark.nvim is a Neovim-first R language tooling product. Before starting a change,
read `AGENTS.md`, `SPEC.md`, and the relevant subsystem notes. New work should
advance the Neovim plugin, detached `ark-lsp`, or managed-session bridge; it
should not expand inherited Positron, Jupyter, notebook, or DAP surfaces.

## Report a bug first

For user-visible bugs, open an issue with a minimal reproduction and a reviewed
`:Ark report`. Never post bridge auth tokens, private source/R values, or whole
unrelated logs. For behavior regressions, add a failing test that reproduces the
real editor/runtime shape before changing production code.

## Development setup

Contributors need Neovim 0.11.3 or newer, R 4.2 or newer, tmux for the canonical
backend tests, and the repository toolchains:

- Rust 1.97.0 from `rust-toolchain.toml`
- `nightly-2025-07-18` rustfmt from `rustfmt-toolchain.toml`
- `jsonlite`; deeper tests also use packages such as `data.table`, `targets`,
  and `tidyselect`

Build the active product root with:

```sh
cargo build -p ark-lsp
```

Set `ARK_NVIM_DEV_MODE=1` only for a contributor checkout. Normal users consume
the optimized artifact belonging to their pinned plugin release.

## Verification

Use the cheapest test that proves the contract while developing, then widen in
proportion to risk:

```sh
scripts/run-e2e-test.sh --init NONE tests/e2e/<focused-test>.lua
just verify-product
scripts/run-full-suite.sh --tier full
```

Run full-TUI tests through the prepared fixture described in `docs/testing.md`.
Do not run tmux-backed full-config journeys concurrently; they share managed
session assumptions. Rust changes must pass the pinned formatting command and
the relevant clippy/test gates. Bridge changes must pass `scripts/check-arkbridge.sh`.

## Pull requests

Keep changes scoped and update `SPEC.md` when a durable product contract changes.
Update user documentation and `CHANGELOG.md` for user-visible behavior. State:

- what contract changed and why
- the failing test observed before a bug fix
- focused and broader passing verification
- compatibility, performance, and release implications
