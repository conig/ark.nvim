# Changelog

All notable user-facing changes to Ark.nvim are documented here. This changelog
covers the Neovim product; inherited Ark/Jupyter history remains available in
the canonical `posit-dev/ark` repository.

## Unreleased

- Added strict, path-aware configuration validation and a stable user-visible
  runtime state model.
- Added `:Ark report`, a preview-first redacted diagnostic report, and expanded
  read-only health checks for component compatibility and writable state.
- Added native `:help ark`, troubleshooting, architecture, compatibility,
  upgrade, and rollback documentation.
- Isolated inherited Positron/Jupyter documentation under `doc/upstream/`.
- Added manifest-driven test tiers, a real `arkbridge` testthat suite, pinned
  full-TUI fixtures, and repeated performance baselines/artifacts.
- Made the detached `ark-lsp` build exclude attached kernel `Console`, R-thread,
  TCP-host, and UI callback infrastructure through a Cargo-enforced feature
  boundary; the retained upstream `ark` host opts in explicitly.
- Consolidated static and live completion planning on one Rust
  handled/unique/composite model and removed source-text semantic heuristics
  from the Blink adapter.
- Prevented status watches from redelivering a ready-session payload while its
  startup bootstrap is still in flight, avoiding needless session-generation
  churn during completion requests.
- Made help and view requests retry bounded `ContentModified` responses while
  prompt-driven session updates settle, and report manually started ready
  sessions as `live_ready` even when automatic pane startup is disabled.
- Treated a live managed `nvim-console` RPC endpoint as the code-send readiness
  boundary and prevented missing endpoints from falling through to raw tmux
  paste.

## 0.1.0-alpha.1 - 2026-07-10

### Added

- Added the first Linux x86_64 release tier for glibc 2.35 or newer.
- Added a checksummed, versioned `ark-lsp` installer with atomic activation and
  one-step rollback.
- Added embedded product/build metadata through `ark-lsp --version --json`.
- Added product-owned Rust, Neovim, R-package, clean-install, and live-session
  CI gates plus a tag-driven release workflow.

### Changed

- Normal installs prefer the Ark-managed optimized release artifact. Repo-local
  debug binaries now require explicit `ARK_NVIM_DEV_MODE=1`.
- Default Cargo commands build the active `ark-lsp` product root rather than
  inactive inherited kernel/Jupyter/DAP roots.
- Pinned development Rust to 1.97.0 and formatting to
  nightly-2025-07-18.
