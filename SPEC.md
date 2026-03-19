# ark.nvim v1 Spec

## Summary

`ark.nvim` v1 is a Neovim-only R language tooling stack built around a managed tmux pane running interactive `R`.

It keeps code execution and pane-side interaction simple:

- execute code with `vim-slime` + `nvim-slimetree`
- get language intelligence from `ark.nvim`

The project goal is to turn the current upstream Ark snapshot into a local-first Neovim product with a standard LSP server and a live-session bridge to the tmux-managed R process.

Recent completion direction:

- data-derived column completions in nested call contexts should prefer explicit invocation over auto-triggering
- the live completion path should resolve bound `data` inputs from named arguments, positional matching, and pipe roots where practical
- `ggplot(data = ..., aes(...))` is a first-class target workflow for that behavior

## Discovery Findings

### Current repo baseline

- This repo is still upstream Ark: a Rust workspace centered on a Jupyter kernel, Positron integration, an LSP, and a DAP.
- The existing LSP implementation is substantial and worth reusing.
- The current LSP is not directly usable in Neovim because it assumes:
  - a kernel-owned `Console`
  - in-process access to the active R runtime via `r_task()`
  - frontend coordination through Jupyter / Positron channels

### Current Neovim workflow

The user's Neovim config already has the desired execution model:

- `~/.config/nvim/lua/r_tmux_pane.lua`
  - creates or reuses one managed tmux pane
  - now launches R via Ark's repo-local `scripts/ark-r-launcher.sh`
- `~/.config/nvim/lua/plugins/slime.lua`
  - keeps `vim-slime` as transport
  - uses local `~/repos/nvim-slimetree/` for AST-aware send motions
- `~/.config/nvim/lua/configs/lspconfig.lua`
  - currently enables `r_language_server`
- `~/.config/nvim/lua/plugins/rscope.lua`
  - currently attaches `rscope.nvim` to the managed pane
- `~/.config/nvim/lua/plugins/blink.lua`
  - Blink is the active completion engine
  - `rscope` currently participates as a custom source

### Architecture implication

The key constraint is that the real interactive R session lives in tmux, outside the LSP process.

Therefore `ark.nvim` cannot reach v1 by merely:

- renaming Ark
- running the existing Ark LSP over stdio

It also needs a supported bridge from the LSP to the live R session in the managed pane.

## Product Definition

### v1 user promise

For `r`, `rmd`, `qmd`, and `quarto` buffers in Neovim:

- one command or automatic filetype entry starts or reuses one managed tmux pane running `R`
- sending code remains fast and deterministic through `nvim-slimetree` + `vim-slime`
- `ark.nvim` provides first-class R language intelligence through Neovim's LSP client
- when the pane is attached and ready, runtime-aware features use the live session
- when the pane is missing or unhealthy, static analysis still works and the failure mode is explicit

### Startup handoff

Async startup should be event-driven from the launcher's trusted status publication:

- the managed pane and bridge start independently of Neovim's LSP client
- the launcher writes pending / ready / error state to the startup status file
- `ark.nvim` starts one detached LSP client immediately for static features
- when a managed pane exists, the LSP learns bridge identity from the trusted status-file path plus tmux session metadata
- bridge readiness and auth changes are handled inside the running detached LSP, not by rebuilding the client

Avoid designs where Neovim starts a throwaway LSP client and repeatedly polls or restarts it while the bridge is still coming up.

### Bridge lifecycle invariants

The managed-session bridge is runtime state, not process identity.

That means:

- detached `ark_lsp` startup must not depend on the bridge already being live
- bridge port and auth token must be discovered from the trusted status file at request time
- `status = ready` is not sufficient for live requests; the bridge must also be `repl_ready`
- Neovim must not synthesize `repl_ready` for LSP session updates unless it also supplies a live connection shape Rust can trust immediately; otherwise the Lua layer and detached bridge will split on readiness
- bridge status changes may trigger an in-process session refresh and diagnostics refresh, but must not trigger normal LSP stop/start churn
- explicit user restarts remain available as an escape hatch, but they are not the canonical attach path

### Detached binary verification invariant

The tmux-backed Neovim flow runs the built `ark-lsp` binary from `target/debug/ark-lsp`.

That means:

- Rust library tests are necessary but not sufficient when detached LSP behavior changes
- after changing detached-server Rust code, rebuild the real binary before trusting live Neovim or tmux E2E results
- a green `cargo test` run against library code does not prove the tmux-backed path is exercising the new logic
- when live behavior and unit tests disagree, suspect a stale detached binary before suspecting the architecture

### v1 must feel native in Neovim

This means:

- standard LSP integration, not a bespoke completion-only plugin
- Blink consumes the normal `lsp` source
- clear Neovim commands for status, attach, refresh, and health
- tmux and R failures surface as actionable messages, not silent empty results

## Exact Slot-In Plan For The User's Config

`ark.nvim` should replace or absorb these pieces:

1. `r_language_server`
   - replace with `ark.nvim` LSP client setup in `~/.config/nvim/lua/configs/lspconfig.lua`
2. `rscope.nvim`
   - replace with `ark.nvim` plugin setup in `~/.config/nvim/lua/plugins/rscope.lua`
3. `rscope` launcher in `r_tmux_pane.lua`
   - replace launcher path with an `ark.nvim`-owned launcher / pane command
4. Blink custom source
   - remove the custom `rscope` completion source once Ark completions come through LSP

These pieces should stay:

- `vim-slime`
- `nvim-slimetree`
- the single managed-pane workflow
- the user's existing keymap habit of "send code separately from ask for IDE help"

## v1 Scope

### In scope

- Neovim plugin at repo root
- managed tmux R pane lifecycle
- local session discovery and attach
- stdio LSP server binary
- reuse and adaptation of Ark's static LSP features:
  - diagnostics
  - symbols
  - folding
  - selection ranges
  - definitions / references / implementations where already supported
  - code actions already implemented in Ark
- live-session features backed by the managed pane:
  - completions
  - hover
  - signature help
  - help-topic lookups where worth keeping
  - session-derived diagnostics context such as known search-path symbols / installed packages
- health checks and failure reporting
- local developer documentation and tests

### Out of scope

- Jupyter kernel runtime
- Positron comms and UI
- DAP
- variables pane / data explorer / plot panes
- notebook documents or notebook execution
- remote / multi-machine workflows
- Windows managed-pane support
- replacing `nvim-slimetree`
- turning `ark.nvim` into a general REPL transport framework for non-R languages

## Non-Negotiable Architectural Decisions

### 1. Standard LSP transport

v1 must expose a normal stdio LSP server suitable for Neovim.

Not acceptable as the primary path:

- a frontend-specific TCP handshake copied from Positron
- a Blink-only completion backend
- tmux scraping as a substitute for an LSP server

### 2. Session bridge, not per-request send-keys

Runtime-aware language features must use a supported request path into the live R session.

The bridge may be implemented as:

- an R package runtime loaded in the managed pane
- a lightweight injected service started by an `ark.nvim` launcher
- another explicit local IPC service

But it must not rely on:

- sending `source(...)` to tmux for every completion request
- parsing terminal output as the normal query mechanism

### 3. Single managed pane for v1

v1 targets one managed R pane per Neovim instance.

This matches the user's current workflow and avoids premature session-routing complexity.

### 4. Static-first fallback

The LSP must still provide useful static features without a live R session.

Live-session unavailability should disable only the features that truly require runtime access.

## Proposed Architecture

## Layer A: `ark-lsp`

Responsibilities:

- stdio LSP server
- document store and indexing
- static analysis
- LSP protocol handling
- session-aware request orchestration

Extraction work required:

- remove dependency on Jupyter startup path
- remove dependency on Positron server start messages
- replace `Console` / `r_task()` coupling with an abstract session client interface
- rename Positron-specific settings and custom method names

## Layer B: `ark-session`

Responsibilities:

- connect the LSP to the tmux-managed live R session
- expose runtime queries needed by Ark's LSP features
- publish session identity and readiness state
- handle auth / trust for local IPC

Minimum query surface for v1:

- current library paths
- installed packages
- search path / visible object names
- callable argument names
- object member completions
- hover/help payloads
- signature help payloads

This layer is the direct replacement for Ark's current in-process `r_task()` access.

## Layer C: Neovim plugin

Responsibilities:

- `setup()`
- pane creation / reuse
- launcher command generation
- attach / reattach behavior
- status and health commands
- LSP client configuration helpers
- custom user commands for refresh / attach / status

Likely commands for v1:

- `:ArkAttachManagedPane`
- `:ArkStatus`
- `:ArkCheckHealth`
- `:ArkRefresh`

## Repository Reshaping

### Desired end state

- root Neovim plugin files:
  - `lua/ark.lua`
  - `lua/ark/...`
  - `plugin/ark.lua`
  - `doc/ark.txt` or equivalent
- Rust crates for:
  - reusable LSP core
  - stdio server binary
  - shared runtime/session protocol types if needed
- optional R package / scripts for session runtime

### Practical migration rule

Do not block v1 on deleting every upstream crate.

It is acceptable to:

- leave `amalthea`, DAP, and kernel code present for a while
- stop wiring them into the shipped product
- progressively extract reusable code into cleaner Neovim-oriented crates

## Workstreams

## Workstream 1: Scope Lock And Naming Cleanup

Deliverables:

- formal project docs
- final public names for:
  - plugin namespace
  - LSP binary
  - session bridge
  - settings keys
  - Neovim commands

Acceptance criteria:

- docs make it impossible to mistake the project for "Ark, but also still Positron"
- `positron.*` is no longer the intended public configuration namespace

## Workstream 2: Extract A Neovim-Usable LSP Core

Deliverables:

- stdio server binary, likely separate from the upstream `ark` kernel entrypoint
- LSP startup independent of Jupyter / Positron server handshakes
- abstract session interface replacing direct `Console` / `r_task()` dependence in LSP handlers

Acceptance criteria:

- Neovim can start the server as a normal LSP process
- static features work in a plain R file without a live session
- no Jupyter connection file or Positron handshake is required

## Workstream 3: Managed Pane Runtime

Deliverables:

- `ark.nvim` launcher script or pane command
- readiness and status markers for the managed pane
- local IPC channel from the tmux R session to the LSP
- robust attach and reattach logic

Acceptance criteria:

- opening an R-family buffer creates or reuses a managed pane
- session identity survives reconnects cleanly
- failures are inspectable through logs and status

## Workstream 4: Runtime-Aware Language Features

Deliverables:

- completions via live session
- hover via live session
- signature help via live session
- session-derived installed-package and search-path context for diagnostics
- library path and help integration as needed

Acceptance criteria:

- member/function completion uses the actual pane session state
- hover and signatures reflect the active session, not a separate embedded R
- static fallback remains usable when session bridge is unavailable

## Workstream 5: Neovim Product Integration

Deliverables:

- root plugin structure
- setup docs
- default LSP config helper
- health commands
- migration instructions from current user config

Acceptance criteria:

- user config can drop `r_language_server` and `rscope.nvim`
- Blink uses normal LSP completion
- `nvim-slimetree` send motions continue unchanged

## Workstream 6: Verification And Release Hardening

Deliverables:

- Rust tests for static LSP behavior
- tmux + live R end-to-end tests
- headless Neovim tests for plugin attach and configuration
- release checklist and operator docs

Acceptance criteria:

- build and tests cover static and live-session paths
- at least one automated or scripted end-to-end proof exists for managed-pane startup plus completion
- failure modes are documented

## Suggested Milestones

### M0: Scope and naming

- complete docs
- finalize public API direction

### M1: Static Ark LSP in Neovim

- stdio LSP binary
- static features working in Neovim

### M2: Managed pane and attach

- launcher
- pane status
- plugin attach commands

### M3: Live-session completions / hover / signatures

- session bridge queries implemented
- runtime-aware features wired through LSP

### M4: Config migration and polish

- replace `r_language_server`
- remove `rscope` dependency in user config
- health checks, docs, failure reporting

### M5: v1 release candidate

- end-to-end verification
- docs and packaging good enough for daily use

## Acceptance Criteria For v1

`ark.nvim` v1 is complete when all of the following are true:

1. In Neovim, `ark.nvim` can be configured as the sole R LSP.
2. Opening an R-family buffer can create or reuse one managed tmux pane running `R`.
3. The LSP server starts over stdio with no Jupyter or Positron dependency.
4. `nvim-slimetree` + `vim-slime` still handle execution without regression.
5. Completion, hover, and signature help work against the live managed R session.
6. Diagnostics, symbols, and other static features still work without a live session.
7. Blink completion works through the standard `lsp` source.
8. Status / health / refresh workflows are documented and usable.
9. Project docs and repo structure clearly present `ark.nvim` as a Neovim-only product.

## Key Risks

### Biggest technical risk

Ark's current runtime-aware LSP handlers assume in-process access to R.

Mitigation:

- define the session client interface early
- move handlers onto that abstraction before large-scale cleanup

### Biggest product risk

Rebuilding too much at once and drifting away from the user's existing workflow.

Mitigation:

- keep `nvim-slimetree` and `vim-slime`
- keep one pane
- focus first on replacing `r_language_server` and `rscope.nvim`, not on inventing a new IDE model

### Biggest scope risk

Trying to carry Positron and Jupyter compatibility through the refactor.

Mitigation:

- treat those systems as reference code only
- do not spend v1 effort preserving them

## Recommended First Implementation Order

1. Create the root Neovim plugin skeleton and document the public API.
2. Introduce a dedicated stdio LSP binary.
3. Extract static LSP paths away from kernel-specific startup.
4. Define the session bridge interface and a minimal managed-pane protocol.
5. Reuse the current managed-pane workflow to launch and attach the live R session.
6. Port completion, hover, and signature help onto the bridge.
7. Replace current Neovim config dependencies one by one.

## Verification Plan

At minimum, every serious milestone should be checked with:

- `cargo` tests for affected Rust crates
- headless Neovim startup for plugin config sanity
- tmux-backed manual or automated proof for:
  - pane start
  - attach
  - completion from live session

Verification should mirror the real editing environment.
Because the target config uses automatic delimiter closing, completion and signature tests should default to cursor-before-close shapes like `foo(bar|)` or `dt[, .(m|)]`, not only truly unclosed forms.
Open-delimiter-only cases are still worth testing, but they are secondary unless the bug explicitly depends on missing closers.

The eventual target command set should include:

- a Rust test command for the LSP core
- a headless Neovim test command
- a tmux / live-R integration test command

These commands should be standardized and added to repo docs as they become real.
