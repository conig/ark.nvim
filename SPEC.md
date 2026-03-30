# ark.nvim Spec

## Purpose

This file captures the architectural state of the Neovim refactor, how it has
departed from upstream Ark, the weaknesses that remain, and the changes that
should define v2.

It does not replace [AGENTS.md](/home/marine/repos/ark.nvim/AGENTS.md). That
file remains canonical for product scope, contributor workflow, and repository
rules. This spec is narrower and more opinionated. It records:

- the actual runtime shape in the repo today
- the meaningful divergence from upstream Ark
- what is working well
- what is still transitional, brittle, or too expensive
- the changes required to reach a clean v2 architecture

## Upstream Divergence

As of 2026-03-20:

- current `ark.nvim` HEAD: `45313412`
- compared upstream ref: `upstream/main` at `9c899e2d`
- merge-base with upstream: `7f8487f2`
- divergence from that merge-base: 148 files changed, about 15.9k insertions and 975 deletions

That divergence is not random churn. It is a deliberate product split away from
upstream Ark's kernel and Positron orientation.

### The primary product departure

Upstream Ark still centers an attached runtime model shaped around:

- kernel startup
- Positron/Jupyter comms
- frontend-specific requests and settings
- an R process that Ark can directly control

`ark.nvim` has moved to a different product boundary:

- one Neovim plugin surface in [lua/ark/](/home/marine/repos/ark.nvim/lua/ark)
- one detached stdio LSP binary in [crates/ark/src/bin/ark-lsp.rs](/home/marine/repos/ark.nvim/crates/ark/src/bin/ark-lsp.rs)
- one tmux-managed interactive `R` pane started by [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh)
- one pane-side bridge runtime under [packages/arkbridge/](/home/marine/repos/ark.nvim/packages/arkbridge/)
- one Neovim-focused E2E suite under [tests/e2e/](/home/marine/repos/ark.nvim/tests/e2e)

### The important architectural departure

The real interactive R session no longer lives inside the LSP process.

That means `ark.nvim` cannot be "upstream Ark over stdio." It must do three
separate things well:

1. manage a pane-owned interactive runtime
2. start a detached language server that behaves like a normal Neovim LSP
3. bridge runtime-aware requests from that detached LSP into the pane-owned R session

### What has intentionally been kept from upstream

The refactor is not a rewrite. The project still sensibly reuses upstream Ark's:

- parser and document model
- indexing and diagnostics infrastructure
- completion, hover, signature, and symbol logic where still applicable
- low-level R integration crates such as `harp` and `libr`

That is the right call. Reusing the analysis core is a strength.

## Current Runtime Shape

The current product is three cooperating layers.

### Managed terminal tabs

`ark.nvim` now supports a tabbed managed-terminal model for Neovim without
showing multiple Ark panes on screen at once.

The intended behavior is:

- exactly one Ark pane is visible beside Neovim at a time
- inactive Ark tabs are parked off-screen in a dedicated detached tmux session
- each parked tab lives in its own tmux window inside that parking session
- switching tabs moves the live pane back into the visible slot and retargets
  both `vim-slime` and the detached LSP session metadata

This design is deliberate.

- It avoids carving up the visible tmux window into many tiny panes.
- It avoids the geometry coupling that would come from storing multiple hidden
  tabs in one parking window.
- It preserves the current Ark architecture of one active live session per
  Neovim instance.
- It stays on the same tmux server so Ark can move the exact live pane back and
  forth with `break-pane` and `join-pane`.

Important constraint:

- parked tabs may temporarily reside in a different tmux session, but the
  launcher snapshots the visible-session identity at startup and Ark only treats
  the restored visible tab as the active bridge target

### Neovim plugin layer

Primary files:

- [lua/ark/init.lua](/home/marine/repos/ark.nvim/lua/ark/init.lua)
- [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua)
- [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
- [plugin/ark.lua](/home/marine/repos/ark.nvim/plugin/ark.lua)

Responsibilities:

- ensure or reuse one managed tmux pane
- locate and start detached `ark-lsp`
- discover session identity and deliver it into the LSP using `ark/updateSession`
- surface commands such as `ArkPaneStart`, `ArkRefresh`, and `ArkStatus`
- integrate with Blink and with the existing `vim-slime` workflow

### Detached LSP layer

Primary files:

- [crates/ark/src/bin/ark-lsp.rs](/home/marine/repos/ark.nvim/crates/ark/src/bin/ark-lsp.rs)
- [crates/ark/src/lsp/backend.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/backend.rs)
- [crates/ark/src/lsp/main_loop.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/main_loop.rs)
- [crates/ark/src/lsp/state.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state.rs)
- [crates/ark/src/lsp/state_handlers.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state_handlers.rs)
- [crates/ark/src/lsp/session_bridge.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/session_bridge.rs)

Responsibilities:

- behave as a normal stdio LSP server for Neovim
- own parsing, document state, indexing, diagnostics, and request handling
- combine static analysis with runtime-aware bridge queries
- bootstrap and report detached session status

### Pane-side runtime layer

Primary files:

- [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh)
- [scripts/ark-wait-for-repl.sh](/home/marine/repos/ark.nvim/scripts/ark-wait-for-repl.sh)
- [packages/arkbridge/](/home/marine/repos/ark.nvim/packages/arkbridge/)
- transitional legacy runtime in [packages/rscope/](/home/marine/repos/ark.nvim/packages/rscope/)

Responsibilities:

- launch interactive `R` inside the managed pane
- bootstrap the local IPC bridge inside that session
- publish startup and readiness metadata to a trusted status file
- answer runtime inspection and bootstrap requests from detached `ark-lsp`

## Current Startup Contract

The startup path today is effectively:

1. Neovim opens an R-family buffer.
2. [lua/ark/init.lua](/home/marine/repos/ark.nvim/lua/ark/init.lua) triggers pane and LSP startup.
3. [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua) creates or reuses a pane and computes the status-file path.
4. [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh) starts `R`, installs or reuses `arkbridge`, and writes startup metadata.
5. [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua) starts detached `ark-lsp` with bridge env pointing at that status file.
6. The plugin sends `ark/updateSession` notifications as the status file changes.
7. [crates/ark/src/lsp/state_handlers.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state_handlers.rs) converts those updates into a `SessionBridge`.
8. [crates/ark/src/lsp/session_bridge.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/session_bridge.rs) bootstraps console scopes and library paths, after which runtime-aware features become fully live.

This contract is viable. It is also still too implicit.

## What Is Working Well

### The product split is directionally correct

The repo is no longer pretending that Neovim is just another frontend for the
old Ark product. The new detached stdio path is real and explicit.

### The reuse boundary is sensible

Keeping the analysis engine and adapting only the runtime boundary is the right
engineering choice. The project is preserving the valuable parts of upstream
instead of rewriting them under deadline pressure.

### The team invested in ecologically valid tests

The repo now has a real Neovim E2E suite, including:

- detached parity coverage in [tests/e2e/detached_parity.lua](/home/marine/repos/ark.nvim/tests/e2e/detached_parity.lua)
- startup and timing coverage in [tests/e2e/full_config_startup_completion.lua](/home/marine/repos/ark.nvim/tests/e2e/full_config_startup_completion.lua)
- managed-session completion coverage in [tests/e2e/subset_completion.lua](/home/marine/repos/ark.nvim/tests/e2e/subset_completion.lua)
- readiness and bridge-state regressions in multiple focused tests under [tests/e2e/](/home/marine/repos/ark.nvim/tests/e2e)

That is the correct testing direction for this product.

### The bridge is the right abstraction

Runtime-aware language intelligence is being routed through an explicit local IPC
boundary rather than per-request `tmux send-keys`. That is the correct UNIX-ish
design: one process owns the REPL, one process owns language serving, and they
communicate over a narrow, explicit protocol.

## Review Findings

These are the highest-value weaknesses remaining in the current implementation.

### 1. There is still no single authoritative startup state machine

The current truth is spread across several partially overlapping signals:

- pane existence in [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
- launcher status-file contents in [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh)
- live bridge ping in [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
- client presence and attachment in [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua)
- detached bootstrap state in [crates/ark/src/lsp/state.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state.rs)

This is the root architectural weakness behind startup flake and confusing
status output. The code has improved substantially, but it still reasons about
one startup across multiple truth models.

### 2. Too much of the orchestration remains large, stateful, and editor-side

The current file sizes are a warning sign:

- [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh): 617 lines
- [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua): 597 lines
- [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua): 603 lines
- [crates/ark/src/lsp/session_bridge.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/session_bridge.rs): 3031 lines

That does not automatically mean the code is bad, but it does mean v2 should
actively simplify and split responsibilities before more behavior accretes there.

### 3. The editor still performs too much synchronous readiness probing

[lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua) derives session
payloads from `tmux.status()`, and [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
uses bridge pings as part of status computation. That is understandable for v1,
but it means the editor is still actively probing the runtime during watcher and
polling activity.

That is correct enough to ship, but it is not the clean final design. In v2,
the runtime should publish authoritative state so the editor is mostly relaying
facts instead of repeatedly discovering them.

### 4. `arkbridge` is still a thin ownership wrapper over `rscope`

The new package name exists, but the runtime is still visibly transitional:

- [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh) still accepts many `RSCOPE_*` variables
- [packages/arkbridge/R/ipc_service.R](/home/marine/repos/ark.nvim/packages/arkbridge/R/ipc_service.R) still uses `.rscope_*` internals
- [packages/arkbridge/src/init.c](/home/marine/repos/ark.nvim/packages/arkbridge/src/init.c) and related C code still export `C_rscope_*` symbols
- [packages/arkbridge/LICENSE](/home/marine/repos/ark.nvim/packages/arkbridge/LICENSE) still names `rscope maintainers`
- [packages/rscope/](/home/marine/repos/ark.nvim/packages/rscope/) is still vendored beside the Ark-owned package

This is the biggest maintainability debt in the runtime layer.

### 5. Generated runtime artifacts are still tracked in the repository

[packages/arkbridge/src/arkbridge.so](/home/marine/repos/ark.nvim/packages/arkbridge/src/arkbridge.so),
[packages/arkbridge/src/init.o](/home/marine/repos/ark.nvim/packages/arkbridge/src/init.o),
[packages/arkbridge/src/ipc.o](/home/marine/repos/ark.nvim/packages/arkbridge/src/ipc.o),
[packages/arkbridge/src/rscope.o](/home/marine/repos/ark.nvim/packages/arkbridge/src/rscope.o),
and [packages/arkbridge/src/rscope.so](/home/marine/repos/ark.nvim/packages/arkbridge/src/rscope.so)
are currently tracked.

That is not a robust long-term distribution story. Generated binaries make the
repository noisier, less portable, and harder to trust.

### 6. The detached Neovim path still carries upstream Positron surface area

The user-facing product boundary has changed, but several detached-path surfaces
still speak upstream language:

- [crates/ark/src/lsp/config.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/config.rs) still uses `positron.r.*` setting keys
- [crates/ark/src/lsp/backend.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/backend.rs) still logs a `Positron` notification path and crash guidance pointing to Positron issues
- several custom method names remain `positron/*` because they were inherited from upstream

This is not a release blocker, but it is product-boundary debt and should be
removed or clearly isolated.

### 7. The test suite is strong overall, but some mocked tests have drifted from the current contract

The live E2E direction is good. The mocked contract tests are less healthy.

At review time, these headless tests fail against the current implementation:

- [tests/e2e/async_startup_notification.lua](/home/marine/repos/ark.nvim/tests/e2e/async_startup_notification.lua)
- [tests/e2e/session_notification_prefers_authoritative_repl_ready.lua](/home/marine/repos/ark.nvim/tests/e2e/session_notification_prefers_authoritative_repl_ready.lua)

Those failures matter because they indicate the mocked `ark.tmux` contract in
the tests has drifted from the current `tmux.status()`-driven startup path.
That weakens confidence in the fast test tier even though the live E2E coverage
is improving.

## v2 Requirements

The following changes should define v2.

### 1. Introduce one canonical startup state machine

The startup path should be represented explicitly and consistently across the
launcher, Neovim plugin, status output, and tests.

At minimum the named phases should be:

1. pane created
2. launcher running
3. bridge reachable
4. client started
5. session update delivered
6. detached bootstrap complete

`ArkStatus`, logging, and tests should all talk about these same phases.

### 2. Make pane readiness explicit from inside `R`

Prompt scraping should no longer be a core readiness contract. It may remain a
send-keys safety signal, but language-intelligence readiness should come from an
explicit runtime signal published by the pane-side runtime.

### 3. Minimize synchronous discovery in Neovim

The plugin should trend toward:

- starting the pane
- starting the client
- reading authoritative runtime state
- relaying that state

It should trend away from repeated probing and derived readiness heuristics in
editor code.

### 4. Finish the Ark-owned runtime migration

v2 should make `arkbridge` genuinely Ark-owned:

- remove `RSCOPE_*` compatibility from the default path
- rename `.rscope_*` R internals
- rename `C_rscope_*` native symbols
- fix package metadata and license ownership
- delete [packages/rscope/](/home/marine/repos/ark.nvim/packages/rscope/) once migration is complete

### 5. Split oversized orchestration modules along clean boundaries

v2 should not add more complexity to the current monoliths.

The preferred split is:

- launcher shell orchestration in shell
- bootstrap and runtime logic in checked-in R sources, not embedded heredocs
- Neovim pane/session discovery separate from LSP lifecycle management
- session-bridge transport separate from R-context parsing and completion-context extraction

### 6. Isolate or remove upstream Positron-facing surfaces from the Neovim path

The detached stdio path should not present Positron branding or Positron-specific
settings as its public contract. Where compatibility must remain, it should be
encapsulated and documented as legacy compatibility rather than default product identity.

### 7. Repair and stratify the test suite

v2 should maintain three clear test layers:

1. Rust unit and integration tests for bridge state, bootstrap, and detached LSP state handling
2. fast headless Neovim contract tests with mocks that actually match current plugin APIs
3. serial live tmux E2Es, plus a small real-config smoke suite

The current mocked test drift needs to be fixed before that layer can be trusted.

### 8. Remove generated artifacts from git

Compiled package outputs should be built or installed as part of the bootstrap
path, not versioned in the source tree.

## v2 Priorities

The priority order should be:

1. define and implement the canonical startup state machine
2. remove prompt-scrape and ping-heavy readiness heuristics from the hot path
3. finish the `rscope` to `arkbridge` ownership migration
4. repair the fast mocked test tier and document a canonical test runner
5. separate Neovim-serving code from inherited Positron/Jupyter surfaces
6. split large orchestration modules before adding more behavior
7. remove generated binaries from version control

## Success Criteria

The project is in good shape when first attach reliably gives the user:

1. one managed tmux pane
2. one detached live `ark_lsp` client
3. truthful `ArkStatus`
4. fast `libr -> library`
5. fast `mtcars$ -> mpg`
6. diagnostics without mysterious late arrival

and does so without:

- prompt-scrape luck
- product-critical `rscope` ownership
- stale bridge-auth churn
- broken fast-path tests
- versioned generated runtime artifacts
