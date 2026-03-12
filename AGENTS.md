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
