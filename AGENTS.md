# AGENTS.md

This file defines the working scope for `ark.nvim` and gives contributors a stable frame for decisions during the refactor from upstream Ark.

## Project Overview

`ark.nvim` is a Neovim-only R language tooling project.

The target product is:

- a native Rust LSP server for R, built from Ark's existing language-analysis code where practical
- a Neovim plugin that starts or attaches to one managed tmux pane running interactive `R`
- a session bridge so the LSP can query the live R session inside that pane for completions, hover, signatures, help, and other runtime-aware features

`ark.nvim` is not a Positron integration, not a Jupyter kernel, and not a notebook runtime.

## Canonical User Workflow

The intended editor workflow is:

1. Open an `r`, `rmd`, `qmd`, or `quarto` buffer in Neovim.
2. `ark.nvim` ensures one managed tmux pane exists and is running `R`.
3. Code execution is still handled by `vim-slime` plus `nvim-slimetree`.
4. Language features are handled by `ark.nvim` through Neovim's LSP client.
5. When a managed R session is available, `ark.nvim` augments static analysis with live-session intelligence.

This separation is deliberate:

- `nvim-slimetree` remains the chunk and statement send layer.
- tmux remains the terminal/session UI.
- `ark.nvim` owns language intelligence, session discovery, and Neovim integration.

## Hard Scope Boundary

### In scope for v1

- Neovim plugin setup and session management
- managed tmux pane lifecycle for a single interactive R session
- standard LSP transport for Neovim, using a stdio server
- Ark-powered R language features inside Neovim:
  - completions
  - hover
  - signature help
  - diagnostics
  - definitions / references / implementations where supported
  - symbols
  - folding and selection ranges
  - code actions already supported by Ark's LSP core
- graceful fallback from runtime-aware features to static-only behavior when no live R session is attached
- local, same-machine operation for tmux-managed R

### Explicitly out of scope for v1

- Positron support
- Jupyter kernel support
- notebook execution or notebook UI
- DAP/debug adapter work
- plots pane, variables pane, data explorer, comms UI, or other Positron frontend surfaces
- replacing `nvim-slimetree` as the send engine
- remote tmux / SSH / multi-host session support
- multi-pane orchestration beyond one managed R pane per Neovim instance
- Windows support for managed-pane mode

If a change improves Positron or Jupyter but does not move the Neovim product forward, it is outside scope.

## Current Repository Reality

This repository currently starts from upstream Ark. That means the tree still contains:

- Jupyter kernel infrastructure in `crates/amalthea`
- the upstream `ark` binary and kernel-oriented startup path
- DAP code
- Positron- and RStudio-specific R modules and comm handlers

Most of that code is reference material during the refactor, not target product surface.

When deciding what to keep, prefer:

1. preserving reusable language-analysis and R-integration code
2. extracting reusable pieces behind new interfaces
3. deleting or sidelining frontend-specific code only after the Neovim replacement path is clear

Do not expand new work in the Jupyter / Positron direction.

## Architectural Direction

The key architectural constraint is that the real interactive R session lives in tmux, not inside the LSP process.

Today the detached Neovim path uses the local `rscope` IPC runtime as that bridge when it is available, with `ark.nvim` responsible for passing trusted session metadata into `ark-lsp`.

That means `ark.nvim` v1 needs three layers:

1. `ark-lsp`:
   - standard stdio LSP server for Neovim
   - owns static analysis, document state, indexing, diagnostics, and LSP protocol handling
2. session bridge:
   - talks to the live R session in the managed tmux pane over a local IPC channel
   - serves runtime-aware queries needed by completion, hover, signatures, help, and session-derived diagnostics/context
3. Neovim plugin:
   - starts or reuses the managed pane
   - discovers and attaches session identity
   - launches the LSP server
   - wires Neovim settings, commands, health checks, and filetype behavior

Per-request tmux text injection is not the target runtime architecture for language intelligence. A managed in-session service is the canonical solution.

## Neovim Integration Target

Discovery in the user's config established the intended slotting:

- keep `vim-slime`
- keep `nvim-slimetree`
- replace `r_language_server` in `~/.config/nvim/lua/configs/lspconfig.lua`
- replace `rscope.nvim` in `~/.config/nvim/lua/plugins/rscope.lua`
- replace the launcher path in `~/.config/nvim/lua/r_tmux_pane.lua` with an `ark.nvim`-owned launcher / pane command
- use Blink's built-in `lsp` source instead of a separate completion source

For v1, contributors should optimize for that integration path rather than inventing a parallel Neovim UX.

## Repository Structure Guidance

Expected long-term shape:

- root Neovim plugin surface:
  - `lua/`
  - `plugin/`
  - `doc/`
- Rust workspace for native pieces:
  - extracted LSP crate(s)
  - reusable R bindings / support crates
- optional R runtime package or scripts for the session bridge

It is acceptable during migration for old upstream crates to remain present, but new feature work should be organized around the Neovim product shape.

## Preferred Extraction Strategy

When refactoring upstream Ark code:

- keep `harp`, `libr`, and other low-level reusable crates if they still fit
- isolate LSP logic from kernel-only concerns
- remove dependencies on `Console`, `r_task()`, Jupyter sockets, and Positron comms from the Neovim-serving path
- rename user-facing configuration and protocol names away from `positron.*`
- treat Positron-specific custom requests as optional unless Neovim v1 needs them

The bar is not "delete upstream Ark quickly." The bar is "produce a clean Neovim-only product boundary."

## Contributor Rules

- Do not add new Positron-specific behavior.
- Do not let Jupyter compatibility drive architecture.
- Prefer a canonical Neovim LSP setup over custom completion plumbing when standard LSP suffices.
- Prefer a single managed-pane model over multi-session abstractions unless a task explicitly requires more.
- Keep runtime/session bridging explicit; do not hide it behind ad hoc tmux scraping.
- If a feature needs the live R session, design the request/response path as a supported bridge API.

## Verification Expectations

No task is complete until the relevant layer is proven:

- Rust LSP logic: unit / integration tests
- Neovim plugin behavior: headless Neovim tests where practical
- tmux + live R integration: end-to-end tests or a documented manual verification path

For v1 work, verification should trend toward:

- stdio LSP startup from Neovim
- attach to managed tmux R pane
- completion, hover, and signature help against a live R session
- static diagnostics and symbols without a live session
- fallback behavior when tmux / R session is unavailable

## Working Effectively In This Repo

These are the highest-value practical discoveries from the current Neovim refactor.

### 1. Distinguish detached LSP work from live-session work

`ark.nvim` runs `ark-lsp` in detached stdio mode.
The interactive R runtime does not live inside the LSP process.

That means most editor features now fall into one of three buckets:

- static-only LSP behavior
- detached LSP behavior augmented by bootstrap/session metadata
- live-session behavior routed through the managed-session bridge

When a feature seems broken, first identify which bucket it belongs to before changing code.

### 2. The session bridge is the runtime boundary

Runtime-aware completions, hover, and signature help should flow through `crates/ark/src/lsp/session_bridge.rs`.

Important rule:

- if a detached request is a real bridge-owned context, returning zero items must still count as "handled"

Otherwise detached fallback sources may run afterward and accidentally touch embedded-R code paths that only make sense in attached/runtime mode.

### 3. Auto-popup issues are often capability issues, not completion logic issues

If a completion works through an explicit `textDocument/completion` request but not while typing, inspect:

- `crates/ark/src/lsp/state_handlers.rs`
- the server's advertised `completionProvider.triggerCharacters`
- the user's Blink trigger configuration

Current trigger characters intentionally include:

- `$`
- `@`
- `:`
- `"`

The double quote trigger matters for:

- comparison-string completions like `x == "`
- subset-string completions like `mtcars[["`

### 4. Subset and comparison precedence matters

Some syntax forms look like multiple completion contexts at once.

Important current rule:

- comparison-string handling must run before generic subset handling

This is required so cases like `DT[col == "` are treated as comparison-value completion instead of generic `[` completion.

### 5. Use the existing E2E harnesses first

The fastest reliable path is usually a headless Neovim test, not a unit test.

High-value harnesses:

- `tests/e2e/comparison_string_completion.lua`
  - comparison values
  - empty-prefix quote-trigger cases
  - factor / character / numeric-no-crash coverage
- `tests/e2e/subset_completion.lua`
  - `mtcars[`
  - `mtcars[, c("`
  - `mtcars[["`
  - `data.table` `[` completion
- `tests/e2e/detached_parity.lua`
  - detached static + bridge parity sanity checks
- `tests/e2e/browser_completion.lua`
  - `browser()` frame symbol completion
- `tests/e2e/library_completion.lua`
  - installed-package completion
- `tests/e2e/completion_resolve.lua`
  - docs/detail resolution
- `tests/e2e/base_diagnostics.lua`
  - detached diagnostics sanity

Recommended verification pattern:

1. run the relevant test with `-u NONE`
2. rerun with the user's real `~/.config/nvim/init.lua`
3. only then widen into adjacent regressions

Do not run the tmux-backed full-config E2Es in parallel.
They share one managed tmux/session contract and will interfere with each other.

### 6. Use the real config when the issue smells like integration

`-u NONE` is best for isolating Ark.
The real config is best for issues involving:

- Blink trigger behavior
- LSP restart behavior
- managed-pane startup timing
- plugin interaction regressions

Do not assume a passing `-u NONE` run means the UX is fixed.

### 7. One-off startup timeouts are not always product bugs

Headless full-config runs have occasionally hit one-off `ark bridge ready` timeouts.
If the failure is a startup timeout and not a semantic regression:

1. retry once cleanly
2. if the rerun passes, treat the timeout as environmental noise unless it becomes reproducible

Do not turn every isolated startup timeout into architecture churn.

### 8. Current Neovim slot-in is already real

The intended integration path is no longer speculative.
This repo is already wired around replacing:

- `r_language_server`
- `rscope.nvim`

while keeping:

- `vim-slime`
- `nvim-slimetree`
- one managed tmux R pane
- Blink's normal `lsp` source

Future work should preserve that model unless the user explicitly changes product direction.

### 9. The launcher/runtime is now owned locally

The external `rscope.nvim` repo is no longer part of the runtime path.

Ark now owns:

- `scripts/ark-r-launcher.sh`
- trusted status files under `ark-status`
- the vendored bridge runtime in `packages/rscope`

If work touches launcher/bootstrap behavior, verify all three layers together:

- tmux pane startup from `lua/ark/tmux.lua`
- launcher/bootstrap behavior in `scripts/ark-r-launcher.sh`
- bridge/runtime behavior in `packages/rscope`

Also keep the readiness split straight:

- `bridge_ready` means the local IPC service is up and answers Ark pings
- `repl_ready` means the tmux pane also shows a stable R prompt and is safe for send-keys style workflows

These states are related but not interchangeable.

### 10. Current performance baseline

Measured rough timings from the real config:

- cold bridge readiness: about 426 to 427 ms
- cold pane + live LSP readiness: about 1079 to 1091 ms
- warm `:ArkRefresh` after restart-fix work: about 121 ms

There may be small wins left, but the current cold path is mostly dominated by tmux split, R startup, bridge readiness, and LSP initialization.

Treat claims of "easy big startup wins" skeptically unless you can measure them.

## Legacy Notes From Upstream Ark

Some upstream conventions remain useful unless and until the code moves:

- use explicit `return Err(anyhow!(...))` instead of `bail!`
- prefer `log::trace!` over `log::debug!`
- prefer fully qualified `anyhow::Result`
- avoid unnecessary `.clone()`
- avoid `.unwrap()` / `.expect()` in production code
- keep functions ordered top-down in call flow where practical
- keep `Cargo.toml` dependency order alphabetical

If these conventions conflict with a cleaner Neovim-only architecture, choose the cleaner architecture and update this file.
