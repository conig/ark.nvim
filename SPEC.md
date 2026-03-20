# ark.nvim Spec

## Purpose

`ark.nvim` is a Neovim-only R tooling project.

Its job is to make one editor workflow feel native and reliable:

1. open an `r`, `rmd`, `qmd`, or `quarto` buffer in Neovim
2. get one managed tmux pane running interactive `R`
3. keep code sending simple through `vim-slime` and `nvim-slimetree`
4. get language intelligence from `ark.nvim` through the normal Neovim LSP client
5. when a live R session exists, augment static analysis with runtime-aware completions, hover, signatures, and session-derived diagnostics context

This project is not trying to be Positron, Jupyter, or a notebook runtime.
It is trying to be the cleanest possible R IDE layer for the user's existing Neovim + tmux workflow.

## Product Boundary

### In scope

- Neovim plugin setup, commands, and health/status reporting
- one managed tmux pane per Neovim instance
- one detached stdio LSP client for Ark-backed language features
- runtime-aware language features routed through a local bridge to the tmux-managed R session
- graceful fallback to static-only behavior when the live session is absent
- local same-machine operation

### Out of scope

- Positron support
- Jupyter kernel support
- notebook UI or notebook execution
- DAP/debugger product work
- data explorer / variables pane / plots pane UI
- remote tmux or multi-host orchestration
- replacing `vim-slime` or `nvim-slimetree`

## Basic Infrastructure

`ark.nvim` currently has three major layers.

### 1. Neovim plugin layer

Main files:

- [lua/ark/init.lua](/home/marine/repos/ark.nvim/lua/ark/init.lua)
- [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua)
- [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
- [plugin/ark.lua](/home/marine/repos/ark.nvim/plugin/ark.lua)

Responsibilities:

- start or reuse the managed tmux pane
- launch or reuse the detached `ark-lsp` client
- publish session metadata into the running client
- surface `ArkStatus`, `ArkRefresh`, pane control, and related commands

### 2. Detached LSP layer

Main files:

- [crates/ark/src/lsp/backend.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/backend.rs)
- [crates/ark/src/lsp/main_loop.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/main_loop.rs)
- [crates/ark/src/lsp/state.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state.rs)
- [crates/ark/src/lsp/state_handlers.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state_handlers.rs)
- [crates/ark/src/lsp/session_bridge.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/session_bridge.rs)

Responsibilities:

- run as a normal stdio LSP server in Neovim
- own documents, parsing, indexing, diagnostics, and protocol handling
- combine static analysis with runtime-aware bridge queries when available
- keep detached session state truthful and inspectable

### 3. Pane-side runtime layer

Main files:

- [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh)
- [scripts/ark-wait-for-repl.sh](/home/marine/repos/ark.nvim/scripts/ark-wait-for-repl.sh)
- [packages/arkbridge/](/home/marine/repos/ark.nvim/packages/arkbridge/)

Responsibilities:

- start R in the managed pane
- start the local IPC service inside that interactive process
- publish trusted startup status for the pane
- answer runtime queries from the detached LSP

## Current Architecture

The key constraint is simple:

- the real R session lives in tmux
- the LSP process does not own that R runtime

So `ark.nvim` cannot be “just upstream Ark over stdio”.
It needs a supported bridge from the detached LSP to the live pane-owned R session.

That means the intended data flow is:

1. Neovim opens an R-family buffer.
2. `ark.nvim` ensures the tmux pane and launcher exist.
3. The launcher starts R and the pane-side IPC service.
4. `ark.nvim` starts `ark-lsp` in detached mode.
5. `ark.nvim` sends trusted session metadata into `ark-lsp`.
6. `ark-lsp` uses static analysis by default and the bridge for runtime-aware requests.

## Why `rscope` Was Used

Historically, the easiest bridge already available for this shape was the old `rscope` runtime:

- a small R package with inspection helpers
- a local IPC service
- some member completion and object inspection logic

That let the repo prove that a tmux-managed detached Ark flow was possible.
It was a pragmatic bootstrap step.

## Why `rscope` Is Now a Problem

The old `rscope` dependency is now architectural drag.

### Product clarity problem

`ark.nvim` is meant to be an Ark-owned Neovim product.
Continuing to route core runtime behavior through `rscope` muddies ownership and product boundaries.

### Naming and trust problem

The current runtime still contains:

- `RSCOPE_*` env compatibility
- the vendored `packages/rscope` package
- old package-level helpers and naming

That makes the runtime feel transitional instead of canonical.

### Maintenance problem

Important behavior has been living in a legacy package we are trying to retire:

- member extraction
- inspection payload shaping
- IPC service behavior
- launcher installation expectations

That is backwards. The new product should not deepen its dependency on the thing it intends to remove.

## Deprecation Direction

The goal is not “keep `rscope` forever but rename some commands”.
The goal is:

1. keep only the minimum bridge behavior needed to support Neovim
2. move that bridge under Ark-owned naming and ownership
3. shrink and eventually delete the vendored `rscope` runtime

The current intermediate step is [packages/arkbridge/](/home/marine/repos/ark.nvim/packages/arkbridge/), which is the beginning of that Ark-owned pane runtime.

## Weak Points We Have Identified

### 1. Truthful readiness

For a long time, Ark could look healthy while the detached LSP was still not hydrated.

Examples:

- tmux pane exists
- launcher status file says `ready`
- bridge answers pings
- but `ark_lsp` still has no session-derived scopes or library paths

This led to false confidence from status output.

### 2. Startup contract split across layers

There are several notions of “ready”:

- pane exists
- IPC service started
- tmux prompt is stable
- detached `ark-lsp` client exists
- detached client has actually consumed the session update
- detached client has successfully bootstrapped its runtime inputs

If these are not separated cleanly, bugs appear as:

- missing completions on first attach
- diagnostics coming online late
- status reporting that says “fine” when the useful path is still broken

### 3. Prompt scraping is brittle

Prompt detection based on the visible tmux line is not a robust contract.

Why it is weak:

- `.Rprofile` can change the prompt
- browser/debug prompts differ
- tmux pane capture is a UI scrape, not an authoritative runtime signal

The detached LSP should not block runtime-aware language features on prompt text.

### 4. Client attachment churn

Some failures are not bridge failures at all.
They are “no live `ark_lsp` client for this buffer” failures.

That distinction matters because:

- no client means no completion requests are even possible
- a live but unhydrated client is a different problem
- the status tooling must tell those apart

### 5. Integration fragility with real Neovim config

Synthetic headless tests can pass while the real workflow still fails.

Common causes:

- actual lazy-loading order
- real Blink behavior
- real async startup timing
- plugin interaction and restart churn

This repo must keep testing under the user's real `~/.config/nvim/init.lua` for the critical path.

## Current Strategic Decisions

### Detached hydration must depend on bridge reachability, not prompt text

This is the most important design correction from recent work.

For completions and diagnostics:

- if the Ark bridge is reachable, detached `ark-lsp` should hydrate
- prompt readiness should remain relevant only for pane-send workflows

That split is cleaner and more future-proof.

### `ArkStatus` must report useful state, not comfort text

Status output should let a user distinguish:

- no client
- client exists but is not attached to this buffer
- client exists but is not live
- client is live but detached bootstrap failed
- bridge identity is missing or stale
- session update was received but bootstrap never completed

If `ArkStatus` does not answer those questions, it is not doing its job.

### Runtime bridge requests are the canonical path

The intended architecture is not per-request `tmux send-keys`.
It is:

- one managed pane
- one in-session bridge service
- detached LSP requests over local IPC

That is the only shape that scales cleanly to robust completions, hover, signatures, and session-aware diagnostics.

## Opportunities For Future Elegance

### 1. Replace prompt scraping with explicit runtime readiness

The pane-side runtime should publish a real readiness signal from inside R, not infer it from terminal output.

That would allow:

- cleaner separation between bridge readiness and send-keys safety
- fewer tmux heuristics
- less startup flake

### 2. Finish the `arkbridge` transition

The long-term elegant shape is:

- Ark-owned package name
- Ark-owned IPC/runtime API
- Ark-owned environment variable names
- no product-critical behavior living in `packages/rscope`

### 3. Make status reporting first-class diagnostics

The right `ArkStatus` output should effectively be a startup trace snapshot:

- client presence
- buffer attachment
- session bridge source
- last session update
- last bootstrap attempt
- last bootstrap error
- useful timing fields

This will save more debugging time than another round of vague recovery logic.

### 4. Separate startup phases explicitly

A cleaner model would name and preserve explicit phases such as:

- pane created
- IPC service reachable
- client created
- session update delivered
- detached bootstrap complete

Then both tests and user-facing status could reason about the same state machine.

### 5. Shrink the Neovim-side heuristics

The most elegant long-term design is one where Neovim mostly:

- starts the pane
- starts the client
- passes trusted session identity

and the rest is handled by:

- an explicit pane runtime contract
- an explicit detached LSP state machine

The fewer UI heuristics the plugin carries, the better.

## Success Criteria

The project should be considered healthy when the normal workflow reliably does this on first attach:

1. open an R-family buffer
2. get one managed pane and one detached `ark_lsp` client
3. see truthful `ArkStatus`
4. get `libr -> library`
5. get `mtcars$ -> mpg`
6. get diagnostics without waiting for mysterious late hydration

And it should do that without leaning on legacy `rscope` ownership or prompt-scrape luck.

## Immediate Priorities

1. keep the detached startup contract truthful and deterministic
2. continue migrating pane runtime ownership from `rscope` to `arkbridge`
3. make `ArkStatus` diagnostic-grade
4. keep real-config regressions for startup, completions, and diagnostics
5. prefer deleting transitional compatibility once the Ark-owned path is proven
