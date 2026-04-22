# ark.nvim Spec

## Addressing bugs

NEVER paper-over a bug by adding a recovery branch. This just hides bugs, slows things down in ways that are hard to identify, and adds tech debt.

## Purpose

This file captures the current product boundary of `ark.nvim` as it exists in
the repository today. It is intentionally narrower than [AGENTS.md](/home/marine/repos/ark.nvim/AGENTS.md):

- `AGENTS.md` defines scope, contributor rules, and verification posture
- this file defines the actual runtime shape, public contract, and near-term
  hardening priorities

The spec should track the current tree. It is not a historical roadmap.

## Product Boundary

`ark.nvim` is a Neovim-first R tooling stack with three active layers:

1. a Neovim plugin
2. a detached stdio LSP server, `ark-lsp`
3. a pane-side R bridge runtime, `arkbridge`

The managed-session contract between those layers is backend-neutral, but tmux
is still the canonical and best-supported session backend.

The default intended workflow is:

1. Open an `r`, `rmd`, `qmd`, or `quarto` buffer inside tmux.
2. `ark.nvim` starts or reuses one managed tmux pane running interactive `R`.
3. `vim-slime` and `nvim-slimetree` remain the code-send path.
4. Neovim talks to `ark-lsp` over stdio for static language features.
5. `ark-lsp` uses `arkbridge` to augment those features with live-session data.

Additional session backends may be added behind the same contract, but they are
additive. They must not force tmux behavior down to a least-common-denominator
UX.

Today that includes a built-in Neovim terminal backend for users who want a
managed live R session without tmux. It intentionally starts narrower than the
tmux path: one session, no tmux tab parking semantics, and send-path
configuration routed through `vim-slime` / `nvim-slimetree`.

This repository still contains upstream kernel, Jupyter, Positron, and DAP
code as retained extraction material. That is not the primary product surface.
The legacy `ark` kernel binary is now treated as an opt-in extraction artifact
rather than part of the default build or release path.

## Current Runtime Shape

### Plugin layer

Primary surfaces:

- [lua/ark/init.lua](/home/marine/repos/ark.nvim/lua/ark/init.lua)
- [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua)
- [lua/ark/session.lua](/home/marine/repos/ark.nvim/lua/ark/session.lua)
- [lua/ark/session_runtime.lua](/home/marine/repos/ark.nvim/lua/ark/session_runtime.lua)
- [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
- [lua/ark/terminal.lua](/home/marine/repos/ark.nvim/lua/ark/terminal.lua)
- [plugin/ark.lua](/home/marine/repos/ark.nvim/plugin/ark.lua)
- [lua/ark/health.lua](/home/marine/repos/ark.nvim/lua/ark/health.lua)

Responsibilities:

- select the configured session backend while keeping tmux as the canonical path
- manage one visible Ark tmux pane plus parked Ark tabs on the tmux backend
- manage one visible Ark terminal split on the terminal backend
- configure `vim-slime` / `nvim-slimetree` targeting at the backend seam
- start detached `ark-lsp`
- relay session metadata through `ark/updateSession`
- expose commands such as `ArkPaneStart`, `ArkTab*`, `ArkHelp`, and `ArkStatus`
- expose a dedicated `ArkView` tabpage data explorer for live tabular objects
- expose `:checkhealth ark` for install/runtime diagnostics

### Detached LSP layer

Primary surfaces:

- [crates/ark-lsp/src/main.rs](/home/marine/repos/ark.nvim/crates/ark-lsp/src/main.rs)
- [crates/ark-lsp-core/src/lsp/](/home/marine/repos/ark.nvim/crates/ark-lsp-core/src/lsp/)
- [crates/ark/src/lsp/backend.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/backend.rs)
- [crates/ark/src/lsp/state_handlers.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/state_handlers.rs)
- [crates/ark/src/lsp/session_bridge.rs](/home/marine/repos/ark.nvim/crates/ark/src/lsp/session_bridge.rs)

Responsibilities:

- behave as a normal stdio LSP for Neovim
- own the detached `ark-lsp` workspace package and executable entrypoint
- keep the shared LSP implementation in one source-of-truth tree, with only the
  attached/detached adapter files remaining local to `ark` and `ark-lsp`
- provide diagnostics, hover, completion, signature help, symbols, and related
  static analysis features
- hydrate detached runtime state from trusted session metadata and bridge
  bootstrap data
- route runtime-aware requests across the local bridge boundary

Ark-owned custom method names on the Neovim path are now Ark-native:

- `ark/updateSession`
- `ark/internal/bootstrapSession`
- `ark/internal/status`
- `ark/internal/helpText`
- `ark/internal/virtualDocument`
- `ark/textDocument/helpTopic`
- `ark/textDocument/statementRange`
- `ark/inputBoundaries`

### Pane-side runtime layer

Primary surfaces:

- [scripts/ark-r-launcher.sh](/home/marine/repos/ark.nvim/scripts/ark-r-launcher.sh)
- [scripts/ark-wait-for-repl.sh](/home/marine/repos/ark.nvim/scripts/ark-wait-for-repl.sh)
- [packages/arkbridge/](/home/marine/repos/ark.nvim/packages/arkbridge/)

Responsibilities:

- launch interactive `R` in the managed pane
- install or reuse `arkbridge`
- publish trusted startup/readiness metadata under `ark-status`
- keep the control-plane status file small and store cached bootstrap payloads in
  a separate trusted artifact
- answer bridge requests for bootstrap, help text, and runtime inspection
- answer bridge requests for live data-explorer sessions and table paging

The active runtime contract is Ark-native. Legacy `rscope` compatibility is not
part of the default supported path.

## Current Behavior That Should Be Preserved

- tmux remains the canonical managed backend and must not become second-class in
  pursuit of backend agnosticism.
- One managed live R session per Neovim instance, with Ark tab switching
  implemented by parking inactive sessions in hidden tmux windows.
- The managed pane slot defaults to stacked top/bottom at 50:50 for narrow
  tmux windows and otherwise side-by-side, while remaining overridable through
  plugin configuration.
- Detached startup can begin immediately and hydrate later through trusted
  status-file data plus bridge bootstrap.
- Existing detached binaries and pane-side bridge runtimes should not force
  source-tree freshness scans on the immediate startup path; those checks may
  run shortly afterward in the background instead.
- Startup diagnostics should retain the existing pane and LSP readiness
  milestones, but the user-facing "main buffer unlocked" mark should be
  recorded directly from successful detached session bootstrap when that signal
  is available. `SafeState` remains a fallback for paths that do not get an
  explicit bootstrap-complete event.
- Unnamed scratch startup should only reuse the current working directory as
  the LSP workspace root when that directory resolves to a real project root;
  otherwise Ark should fall back to a dedicated scratch workspace. The same
  fallback should apply to direct home-directory files like `~/.R`, so
  starting from `~` does not accidentally widen startup scope to the whole
  home directory.
- Command-driven startup from an R buffer should prewarm detached `ark-lsp`
  before or alongside managed-pane startup rather than serializing "pane first,
  LSP later". That prewarm path should avoid background session notification
  ladders until the real managed-session bootstrap path takes over.
- Sync startup must hand off cleanly when Neovim has started `ark-lsp` but the
  client is still initializing: status should surface a pending client instead
  of reporting a false bootstrap failure.
- Diagnostics remain syntax-first during detached startup and only become fully
  session-aware after hydration completes.
- Missing-package diagnostics for `pkg::foo`, `library(pkg)`, and `require(pkg)`
  should rely on the current installed-package snapshot or lazy library-path
  metadata, without forcing an eager installed-package enumeration on the
  startup path.
- R Markdown / Quarto fenced chunks work for completion and diagnostics, and
  inline `` `r ...` `` expressions complete as R code.
- Blink integration stays on the normal `lsp` source, with Ark-specific provider
  policy handled in plugin code rather than a generic snippets completion source.
- Structural code templates are exposed explicitly through the Ark Snacks picker
  command instead of ambient completion menus.

## What Is Essentially Complete

- Core v1 Neovim workflow
- Managed pane startup and restart
- Detached `ark-lsp` startup
- Live-session completion, hover, and signature help
- Browser-frame completion
- Ark help float and help-to-pane workflows
- ArkView live data explorer for tabular R objects
- Managed tab commands
- R Markdown / Quarto fenced-chunk completion and diagnostics
- R Markdown / Quarto inline `` `r ...` `` completion
- Safety-oriented E2E runner for tmux-backed and Blink-backed tests

## Open Work After This Tranche

These are still legitimate follow-ups, but they are not required to treat the
current tree as a usable v1 product:

1. simplify startup/readiness orchestration into a clearer canonical state model
2. turn `crates/ark-lsp-core` from a shared source tree into a true standalone
   library crate by extracting the remaining host hooks (`console`, `r_task`,
   `analysis`, `fixtures`, and `url`) and then shrinking the local adapters in
   `crates/ark` and `crates/ark-lsp`
3. continue reducing inherited upstream surface area in retained kernel/Jupyter code

## Completion Architecture Hardening

Completion behavior is now broad enough that it needs one canonical model.

Today the Rust side already has a coherent completion engine:

- literate-R normalization is server-owned
- static completions are organized as `unique` and `composite` sources
- detached runtime completions already use an explicit `CompletionPlan`

The main technical debt is that Ark also re-derives semantic completion context
in the Blink adapter. That duplication currently lives in
[lua/ark/blink.lua](/home/marine/repos/ark.nvim/lua/ark/blink.lua) and includes:

- regex-based detection of string, subset, frontmatter, and inline-`r` contexts
- trigger-specific suppression of non-LSP providers
- timing and recovery patches that exist because the client and server do not
  share one completion-intent model

The canonical direction is:

- Rust owns completion intent for Ark filetypes.
- Blink owns menu presentation, window coordination, and editor-specific glue.
- Ark should not maintain parallel semantic context detectors in Lua and Rust.
- The existing `unique` / `composite` source taxonomy should be preserved unless
  planner work proves it is fundamentally insufficient.

### Canonical Model

Near-term completion work should converge on one planner in Rust that answers:

- is this completion context handled, suppressed, or not applicable?
- is the result exclusive or compositional?
- which source families are allowed in this context?
- when detached runtime data is available, should it replace or merge with
  static items?
- when the context is intentionally empty, should that still count as handled?

This should generalize the detached bridge `CompletionPlan` model instead of
inventing a second planner for static completions.

For Ark filetypes, the semantic region model also belongs in Rust:

- R files: normal code everywhere
- literate-R files: fenced R, inline `` `r ...` ``, frontmatter, and prose must
  be classified by the server-side document/context layer

The Blink adapter may still decide how to display or hide a menu, but it should
not decide whether `"` means comparison-value completion, package-string
completion, frontmatter completion, or plain prose.

### Non-Goals

This refactor is not a rewrite of the completion engine.

Out of scope:

- replacing Blink
- introducing a custom Ark completion source instead of Blink's normal `lsp`
  source
- rewriting all completion sources away from the current `unique` /
  `composite` organization
- expanding ambient prose completion as a feature in its own right

### Migration Sequence

1. Extract a shared completion-planning layer in `ark-lsp-core` that can be
   used by both static completion entrypoints and detached bridge completion.
2. Move context classification that is currently mirrored in Lua into Rust so
   subset, string, namespace, frontmatter, inline-R, package-call, and similar
   precedence rules are decided in one place.
3. Keep detached bridge request construction as an execution detail behind that
   planner rather than as the owner of the planner itself.
4. Thread planner results through `handle_completion()` so attached and
   detached modes follow the same classification order even when the eventual
   execution path differs.
5. Shrink `lua/ark/blink.lua` to Ark-specific Blink integration only:
   source registration, cursor normalization, optional autopair recovery, and
   completion/docs/signature-float coordination.
6. Remove Lua regex policy branches once equivalent planner-backed behavior is
   proven by tests.

### Acceptance Criteria

The refactor is successful when these conditions hold:

- attached and detached completion use the same context-classification order
- `.Rmd` / `.qmd` / `quarto` completion semantics are decided server-side
- Blink no longer needs semantic regexes to determine whether a trigger belongs
  to subset, string, frontmatter, or inline-R completion
- Ark filetypes keep Blink's standard `lsp` source as the primary automatic
  completion path
- runtime-aware completion can still return an intentionally handled empty set
  without falling through to unrelated sources
- stray menu persistence bugs are no longer caused by disagreement between the
  LSP's semantic context and Blink's local heuristics

### Verification Expectations For This Tranche

This refactor is not done until it is proven at both levels:

- planner and precedence logic: Rust unit tests
- request semantics: direct `textDocument/completion` tests
- real interactive behavior: tmux-backed or real-config TUI tests that prove
  Blink-visible behavior while typing

High-value regression coverage for this tranche includes:

- extractor completion
- subset and string-subset completion
- comparison-string completion
- package-string and argument-string completion
- frontmatter output completion
- inline `` `r ` `` empty-prefix completion
- prose `.Rmd` cases where non-semantic completion must not leave stale Blink
  UI behind

## Verification Standard

No change to the active Neovim path is done until it is proven at the right
layer:

- Rust/LSP code: `cargo check`, unit tests, and relevant Rust integration tests
- plugin/session orchestration: focused headless Neovim tests
- live workflow: serial tmux-backed E2Es and a repo-owned Blink-backed smoke path via
  [scripts/run-e2e-test.sh](/home/marine/repos/ark.nvim/scripts/run-e2e-test.sh)
- clean-room user smoke: the Docker harness under
  [docker/readme-minimal/](/home/marine/repos/ark.nvim/docker/readme-minimal)
  must wrap the same [testing/readme-minimal/](/home/marine/repos/ark.nvim/testing/readme-minimal)
  config rather than maintaining a second minimal setup
- ambient user-config smoke remains optional via `--init ~/.config/nvim/init.lua`

High-value smoke coverage for the current product boundary includes:

- startup/session notification tests
- subset and comparison completion
- browser completion
- library completion
- Rmd/Qmd chunk completion and diagnostics
- Blink-backed startup completion

Completion coverage should stay explicitly layered:

- direct `textDocument/completion` tests are valid for LSP and bridge semantics
- they are not sufficient by themselves to prove interactive completion UX
- when a completion bug presents as "works on explicit request but not while typing",
  add both a request-level regression and a real-config regression that types into
  the buffer and proves Blink-visible behavior

## Release-Heuristic Summary

Treat `ark.nvim` as:

- feature-complete enough for the intended v1 Neovim workflow
- not architecture-complete in the broader “final form” sense
- primarily in a polish, identity, and hardening phase rather than a broad
  feature-expansion phase
