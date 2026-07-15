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

## Release And Compatibility Contract

`release-manifest.json` is the single product-version and compatibility source
for the plugin, detached LSP build, bridge launcher metadata, release asset
names, release channel, and release notes. The current channel is `alpha`; its
planned release remains unpublished. When it is published manually, alpha and
beta releases must be marked as prereleases and must not be marked latest. The
first product release line uses exact product
version compatibility across plugin and `ark-lsp`, plus bridge schema `v1`.
Version skew must be reported as an actionable incompatibility rather than
silently treated as a healthy live session.

Normal users pin the plugin to the exact manifest release tag. A floating
`main` checkout is a contributor/development lane because pairing it with a
tagged binary can create product skew. Upgrades change that pin, sync the plugin
and matching artifact, then restart the managed pane and refresh the LSP.
Rollback follows the same whole-product rule: pin and load the previous plugin
release before activating its binary. The rollback command refuses a previous
binary whose product version, target, optimized profile, or bridge schema does
not match the active plugin contract.

The first release tier is deliberately narrow:

- Linux x86_64
- glibc 2.35 or newer, enforced by building release assets on Ubuntu 22.04
- Neovim 0.11.3 or newer
- R 4.2 or newer
- tmux as the canonical backend, with the built-in terminal backend additive

macOS remains a source-build/contributor path until it has a clean artifact and
live-session release verification. Windows managed sessions remain outside the
product boundary.

Normal installation uses a raw optimized `ark-lsp` release asset and a
separate SHA-256 file. Ark installs immutable versions under
`stdpath("data") .. "/ark/releases"`, smoke tests the embedded version, target,
release profile, and bridge schema, then atomically changes the `current`
symlink. The prior
working target remains under `previous`; failed downloads, checksum failures,
wrong component versions, and failed smoke checks leave `current` untouched.
The installer serializes updates with an ownership-checked lock, preserves live
installers, and reclaims orphaned locks after a crash. No elevated privileges
or global `PATH` mutation are required.

Binary discovery is explicit:

1. `ARK_NVIM_LSP_BIN`
2. the Ark-managed current release
3. `ark-lsp` on `PATH`
4. a repo-local optimized source build

A repo-local debug build is considered only when `ARK_NVIM_DEV_MODE=1`.
Normal startup may use an existing repo-local optimized build, but it never
scans Rust sources or invokes Cargo. Contributor rebuilds remain explicitly
available through `:ArkBuildLsp`. In development mode, existing repo-local
binaries receive one coalesced freshness probe after Neovim becomes idle;
source discovery uses asynchronous `rg --files`, and a missing `rg` skips the
automatic probe with an actionable warning instead of recursively globbing the
checkout.

`just verify-product` is the authoritative routine product gate. It uses exact
Rust and rustfmt toolchains and covers the active Rust crates, `arkbridge`, the
installer/rollback contract, a release-artifact clean install, static LSP
startup, live bridge attach, and a Rust-free README container. `just verify`
is the full pre-release suite, `just verify-upstream-compat` exercises retained
workspace compatibility, and `just benchmark` runs the canonical local
performance suite.

Packaging and publication are intentionally manual. The release operator must
verify that `v<product-version>` matches the manifest, run every pre-release
command above, use `scripts/package-release.sh` to create the optimized binary,
SHA-256 checksum, and build metadata, clean-install that exact package, and
review the retained logs before creating a tag or publishing any asset. The
planned `0.1.0-alpha.1` release remains unpublished until that procedure is
performed explicitly.

## Current Runtime Shape

### Plugin layer

Primary surfaces:

- [lua/ark/init.lua](/home/marine/repos/ark.nvim/lua/ark/init.lua)
- [lua/ark/runtime_controller.lua](/home/marine/repos/ark.nvim/lua/ark/runtime_controller.lua)
- [lua/ark/console.lua](/home/marine/repos/ark.nvim/lua/ark/console.lua)
- [lua/ark/console_ansi.lua](/home/marine/repos/ark.nvim/lua/ark/console_ansi.lua)
- [lua/ark/console_transcript.lua](/home/marine/repos/ark.nvim/lua/ark/console_transcript.lua)
- [lua/ark/startup_state.lua](/home/marine/repos/ark.nvim/lua/ark/startup_state.lua)
- [lua/ark/help_render.lua](/home/marine/repos/ark.nvim/lua/ark/help_render.lua)
- [lua/ark/target_actions.lua](/home/marine/repos/ark.nvim/lua/ark/target_actions.lua)
- [lua/ark/lsp.lua](/home/marine/repos/ark.nvim/lua/ark/lsp.lua)
- [lua/ark/lsp_request_adapter.lua](/home/marine/repos/ark.nvim/lua/ark/lsp_request_adapter.lua)
- [lua/ark/lsp_session_watch.lua](/home/marine/repos/ark.nvim/lua/ark/lsp_session_watch.lua)
- [lua/ark/lsp_recovery.lua](/home/marine/repos/ark.nvim/lua/ark/lsp_recovery.lua)
- [lua/ark/session.lua](/home/marine/repos/ark.nvim/lua/ark/session.lua)
- [lua/ark/session_runtime.lua](/home/marine/repos/ark.nvim/lua/ark/session_runtime.lua)
- [lua/ark/tmux.lua](/home/marine/repos/ark.nvim/lua/ark/tmux.lua)
- [lua/ark/terminal.lua](/home/marine/repos/ark.nvim/lua/ark/terminal.lua)
- [plugin/ark.lua](/home/marine/repos/ark.nvim/plugin/ark.lua)
- [lua/ark/health.lua](/home/marine/repos/ark.nvim/lua/ark/health.lua)

Responsibilities:

- keep `lua/ark/init.lua` as the composition root and stable public facade;
  feature rendering and target/package actions are delegated to their owning
  modules through narrow injected interfaces
- keep runtime readiness waiters and managed/console session routing in one
  controller, without duplicating mutable ownership in the command facade
- keep `ark.lsp` callable compatibility while status-file watches and Ark
  custom-request adaptation live behind dedicated internal components
- keep console PTY, buffer, completion, and lifecycle state in the console
  controller while streaming ANSI decoding and transcript classification remain
  pure, editor-independent transformations
- reconcile startup through one per-buffer, generation-aware state model with
  independent LSP and managed-session tracks; invalid and stale transitions are
  retained in status rather than silently mutating readiness
- select the configured session backend while keeping tmux as the canonical path
- manage one visible Ark tmux pane plus parked Ark tabs on the tmux backend
- manage one visible Ark terminal split on the terminal backend
- configure `vim-slime` / `nvim-slimetree` targeting at the backend seam
- optionally attach a conservative R-family keymap preset for the recommended
  pane, send, help, ArkView, snippets, and tab workflows
- send text to the active managed R session through the configured backend
- start detached `ark-lsp`
- recover an unexpectedly exited `ark-lsp` with bounded exponential backoff;
  recovery is scoped per workspace, stops after three attempts in a 30-second
  window, remains visibly actionable when exhausted, and never consumes retry
  budget for Ark-owned refresh/replacement stops; this lifecycle containment
  does not turn request failures into silent success or hide their root cause
- show visible detached `ark-lsp` rebuild progress in a floating log window,
  including cargo output, with `q` closing only the window while the build and
  follow-up LSP attach/restart continue
- relay session metadata through `ark/updateSession`
- expose a lazy-load-friendly `:Ark` dispatcher plus compatibility commands such
  as `ArkPaneStart`, `ArkTab*`, `ArkHelp`, and `ArkStatus`
- present `ArkHelp` through a tmux popup containing a read-only Neovim help
  buffer by default when running on the tmux backend inside tmux, with the
  existing in-process Neovim floating help buffer as the fallback and explicit
  float mode; ordinary `ArkHelp` must not force a managed R pane and should ask
  `ark-lsp` for help text through the live bridge when available or the
  detached local-R fallback otherwise; rendered help pages include an Ark-owned
  section table of contents generated from the Rd text structure, and pressing
  Enter on a TOC row jumps within the current help page; rendered help
  references are styled as links and pressing Enter on a reference keeps the
  user inside ArkHelp while navigating to the linked help topic; `H` and `L`
  move backward and forward through ArkHelp page history
- build tmux popup surfaces for ArkHelp, ArkView, and source-Neovim UI attach
  through one shared popup envelope helper; each invocation supplies width,
  height, target pane/client, optional environment, command payload, top-border
  title, and border policy, with bordered titled popups as the default and
  explicit borderless mode reserved for callers that request it
- accept explicit ArkHelp topics from the managed R runtime so R help syntax
  such as `?lm` in managed R panes can route to ArkHelp without reinterpreting
  submitted console input
- expose a dedicated `ArkView` tabpage data explorer for live tabular objects
- open `{targets}` objects from the configured target store through a direct
  target-store ArkView backend, including tmux popup display in auto mode,
  without starting or reusing the managed R pane
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
- compile the product `ark-lsp` without `ark-lsp-core/attached-runtime`; the
  retained upstream `ark` host opts into that feature explicitly, so `Console`,
  serialized attached-R tasks, TCP host startup, and attached UI callbacks are
  absent from the Neovim-serving build
- provide diagnostics, hover, completion, signature help, symbols, and related
  static analysis features
- hydrate detached runtime state from trusted session metadata and bridge
  bootstrap data
- route runtime-aware requests across the local bridge boundary
- isolate bridge admission/TCP transport, wire protocol, and completion planning
  in `session_bridge_runtime.rs`, `session_bridge/protocol.rs`, and
  `session_bridge/completion.rs`; `session_bridge.rs` remains the feature-client
  facade and trusted connection owner

The canonical startup tracks are:

- LSP: `starting` -> `initialized` -> `static_ready` -> `live_hydrated`
- managed session: `requested` -> `bridge_installing` -> `bridge_ready` ->
  `repl_ready`, with explicit `degraded`, `stopping`, and `restarting` states

`bridge_ready` is accepted only from the backend snapshot, `repl_ready` requires
that bridge state, and live hydration is accepted only from the current LSP and
session generation. `:Ark status` exposes the combined phase and both component
tracks.

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
- service the loopback socket from R's public `InputHandler` API only; the
  product runtime does not mutate `R_PolledEvents`, `R_wait_usec`, or other
  non-public R event-loop globals
- install a scoped managed-session help hook that routes simple R `?topic`
  requests back to ArkHelp through the `nvim-console` RPC socket or the parent
  Neovim RPC server, while preserving base R help behavior as fallback
- install a scoped managed-session `View()` hook that routes data-viewer
  requests back to ArkView through the same Neovim RPC path, while preserving
  base R `View()` behavior as fallback
- present every ArkView entry point through a tmux popup UI in auto mode when
  Ark is using the tmux backend inside tmux, so editor and console panes do not
  constrain data-grid inspection; once this popup route is selected, launcher
  failures remain visible instead of silently changing to an in-process tab,
  while explicit `view.display = "tab"` remains the opt-out
- answer bridge requests for live data-explorer sessions, table paging, and
  list/object-tree inspection
- serve ArkView table pages by `offset` and `limit`, preserving `limit = 0` as
  the bridge-layer request for all rows while allowing the Neovim UI to request
  bounded row windows for tall objects
- adapt base-`View()` compatible non-list objects such as atomic vectors,
  arrays, matrices, and `table()` results through `as.data.frame()` into the
  regular ArkView table grid, while routing plain lists to the object-tree
  explorer
- support ArkView filtering through free-text contains filters, numeric
  comparison filters driven by the `<` and `>` prompts on numeric columns, and
  exact value filters chosen from bridge-provided unique values with counts
- render each ArkView column header as a two-row block with the column name
  above its `<class>` label, and keep both rows visible in sticky floating
  headers while scrolling
- format ArkView display-only string cells so empty strings, boundary spaces,
  and repeated spaces remain visually distinguishable without changing raw
  export, filter, sort, or cell-copy semantics
- keep ArkView page rows encoded as row arrays even for one-column tables
- let ArkView list roots open as an expandable object tree with lazy child
  loading, collapsible branches, `S` component search, and a preview pane; when
  a selected node is table-viewable, `<CR>` opens that node in the regular
  ArkView table grid and returning from that grid restores focus to the list
  explorer

The active runtime contract is Ark-native. Legacy `rscope` compatibility is not
part of the default supported path.

### Live runtime request contract

Detached bridge work is isolated from the serialized LSP state loop. A handler
receives an immutable `WorldState` snapshot; requests tied to a document also
capture its URI and version, and every bridge-backed request captures the
detached-session generation. A result is returned only while those values still
match the latest world state. A newer document or session turns the old result
into an LSP content-modified response rather than publishing stale runtime data.
Neovim-side synchronous help, view, and target requests retry that response
within their original deadline; startup bootstrap treats it as a transient
supersession and retries without warning. Automatic completion remains on the
standard LSP client path, which owns its own content-modified retry behavior.

The interactive R process remains single-threaded. Ark admits at most one
bridge operation into R and allows at most eight additional operations to wait.
Queue admission, queue wait, transport, status refresh, and the one permitted
retry all count toward one end-to-end deadline:

- completion, completion resolve, hover, and signature help: at most 1000 ms
- lifecycle/bootstrap work: at most 2000 ms
- help and read-only view/target requests: at most 10 seconds
- package installation and mutating target actions: at most 30 seconds

The configured session timeout may make a latency-sensitive request shorter;
it cannot extend that class beyond its product deadline. Queue saturation and
deadline expiry are ordinary bridge-unavailable outcomes. Completion preserves
its handled-empty precedence and otherwise falls back to the appropriate
static result; hover and signature help fall back to static or empty results;
user-initiated actions return an explicit actionable error.

Dynamic transport retries are narrow: an authentication or stale-session
response may refresh trusted status metadata and retry once when the connection
identity changed. Connection refusal, timeout, decode failure, and an unchanged
status identity are not sleep-retried. Three consecutive transport failures
for one connection open a two-second circuit; a changed trusted connection
identity closes it immediately, and a successful half-open probe closes it
after cooldown. This prevents completion bursts from probing a dead pane while
allowing a healthy replacement bridge to recover without restarting Neovim.

Neovim/tower-lsp cancellation closes the response channel. Cancelled work is
removed before it enters the R queue; once R has accepted an operation, Ark can
only bound the wait with the transport deadline because interrupting arbitrary
interactive R evaluation is not safe. The late result is discarded.

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
  source-tree freshness scans on the immediate startup path. Detached-binary
  checks run shortly afterward only in explicit development mode; normal mode
  does no automatic source discovery or compilation.
- Startup diagnostics should retain the existing pane and LSP readiness
  milestones, but the user-facing "main buffer unlocked" mark should be
  recorded directly from successful detached session bootstrap when that signal
  is available. `SafeState` remains a fallback for paths that do not get an
  explicit bootstrap-complete event.
- When `configure_slime = true`, R-family `vim-slime` sends must revalidate the
  Ark-managed send target before transport. If the previously published tmux
  pane disappeared, Ark should create or restore one managed session, republish
  the target, and then send the user's original text to that fresh target.
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
- Any automatic detached `ark-lsp` rebuild should be visible to the user. Ark
  should not silently compile while a buffer appears partly ready; it should
  show the rebuild log, leave the log closable with `q`, and attach or restart
  the LSP through the existing build-completion listeners when the binary is
  ready.
- Sync startup must hand off cleanly when Neovim has started `ark-lsp` but the
  client is still initializing: status should surface a pending client instead
  of reporting a false bootstrap failure.
- Diagnostics remain syntax-first during detached startup and only become fully
  session-aware after hydration completes.
- When no managed pane is attached, detached `ark-lsp` may hydrate
  side-effect-free baseline metadata from local R: library paths, installed
  packages, default search-path symbols, help text, and member names for
  deterministic attached objects such as default package data frames. This
  baseline must not execute user `.GlobalEnv` state, and live bridge/session
  metadata remains authoritative once a managed session is available.
- Missing-package diagnostics for `pkg::foo`, `library(pkg)`, and `require(pkg)`
  should rely on the current installed-package snapshot or lazy library-path
  metadata, without forcing an eager installed-package enumeration on the
  startup path.
- `:ArkInstallMissingPackages` and `:Ark packages install-missing` should install
  packages named by current missing-package diagnostics in the managed R session,
  prefer `pak::pkg_install()` when `pak` is available, and use a nearby
  `DESCRIPTION` file's `Remotes` field to resolve GitHub package specs.
- The launcher may prepend Ark's private session library while bootstrapping
  `arkbridge`, but it must restore the user's normal `.libPaths()` before
  handing control to the interactive REPL.
- R Markdown / Quarto fenced chunks work for completion and diagnostics, and
  inline `` `r ...` `` expressions complete as R code.
- Function-call completion should respect R's actual argument model. Before
  `=`, Ark may offer formal argument names; after `=`, Ark should treat the
  cursor as an ordinary argument value and must not infer data-frame column
  completions from a nearby `data` argument or nested `ggplot(..., aes(...))`
  context unless a future explicit semantic contract declares that value domain.
- Blink integration stays on the normal `lsp` source, with Ark-specific provider
  policy handled in plugin code rather than a generic snippets completion source.
- Structural code templates are exposed explicitly through the Ark Snacks picker
  command instead of ambient completion menus.
- ArkView table navigation keeps the selected data column synchronized between
  the grid and columns pane. Local `H` and `L` mappings move to the previous or
  next data column and clamp at table edges.
- ArkView keeps the grid column header visible as a sticky header when vertical
  scrolling moves the canonical header line out of view.
- ArkView defaults to whole-object utility, but tall tables are rendered through
  bounded row windows. `]p`, `[p`, `j`, `k`, `gg`, `G`, and half-page movement
  fetch adjacent windows as needed, while export, cell inspection, filter, and
  sort behavior continues to operate on bridge-side full data.
- ArkView object-tree navigation keeps list exploration separate from table
  operations. Expand/collapse and component search operate on object nodes;
  table sort/filter/export/profile behavior remains owned by the nested regular
  table grid after a table-viewable node is opened.

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

## Console Frontends

Ark supports the raw managed `R` prompt and one richer console frontend:
`nvim-console`.

`nvim-console` is the Neovim-buffer console frontend. It uses a normal
Neovim R buffer for the editable input region so Blink and Neovim's LSP client
can provide completion UI, while Ark owns the PTY-backed R process and renders
the prompt virtually. Submitted input is preserved as R code, and R output is
recorded as transcript comments so the buffer remains a valid R document.
Console history and draft editing are buffer-native interactions on the current
input region, not terminal escape-sequence emulation. It is selected with
`session.console_frontend = "nvim-console"` or opened in-process with
`:Ark console`.
For code sends, a managed external `nvim-console` is ready when its R job and
RPC endpoint are live; that transport readiness is independent of bridge
readiness for language features. A missing RPC endpoint must return an explicit
not-ready error and must never fall through to raw tmux paste into the console
UI.
Its completion key policy uses `Tab` to accept a visible Blink completion,
uses `Enter` to dismiss any visible completion and submit the current input,
uses `Alt-Enter` to insert a newline without accepting completion, and uses
`Shift-Tab` as the visible-menu bypass for inserting a literal tab without
accepting completion.
For R plotting and pipe workflows, the console also maps `<leader>\` to append
`|>` and `<leader>=` to append `+`, each opening a new editable continuation
line in the current console input.

The standalone console discovers optional user configuration at
`~/.config/ark.nvim/ark-repl/init.lua`, or the directory selected by
`ARK_NVIM_REPL_CONFIG_DIR`. Ark makes the supported optional plugin paths
available and establishes its console UI defaults before sourcing that file.
Only afterward does it supply fallback Blink and `nvim-autopairs`
configuration, preserving personal setup performed through shared modules from
the normal Neovim runtimepath. Ark-owned console buffer invariants and mappings
are installed later and remain authoritative.

The raw launcher remains the default fallback and must not degrade.

## Named Future Version: v1.1 Target Lens

`v1.1 Target Lens` is the named version for making `{targets}` projects a
first-class Ark concept.

This version exists because the target user workflow is not just editing loose
R scripts. The common high-value workflow is:

1. maintain a project-level targets script, usually `_targets.R`
2. split pipeline declarations across `_target_pipelines/` or similar files
3. define analysis functions in `R/`
4. render `.Rmd` / `.qmd` manuscripts from cached targets
5. iterate by building, invalidating, inspecting, and loading individual targets

`Target Lens` should turn that pipeline graph into editor-native language
intelligence. The goal is not to replace `{targets}`. The goal is to let Ark
understand target names, dependencies, cache state, and cached objects well
enough that editing a manuscript or analysis function feels connected to the
actual pipeline.

### Product Capability

The v1.1 user-facing feature set is:

- complete target names in `tar_read()`, `tar_load()`, `tar_make(names = ...)`,
  `tar_invalidate(names = ...)`, `tarchetypes::tar_render()`, and common
  project helpers that forward to those APIs
- jump from a target reference to the nearest static declaration such as
  `tar_target(clean_data, ...)`, even when that declaration lives in a sourced
  pipeline file
- show references for a target across the configured targets script,
  `_target_pipelines/`, `R/`, and literate documents
- hover a target name to show its command, upstream dependencies, downstream
  dependents, status, last build time, error/warning state, object format, and
  lightweight object metadata when available
- surface target-aware document and workspace symbols so fuzzy navigation can
  find pipeline nodes, rendered reports, and major pipeline sections
- provide code actions or Ark commands for "build this target", "build
  downstream", "invalidate this target", "load this target", "open target log",
  and "show local graph"
- in `.Rmd` / `.qmd`, make target references in inline and fenced R code behave
  like normal symbols rather than opaque strings or bare names
- when safe, provide member and column completion for cached target objects, for
  example `tar_read(clean_data)$`, `targets::tar_read(table1)[["`, and
  manuscript variables assigned from `tar_read()`

### Macro Architecture Change

The current product has three active layers:

1. Neovim plugin
2. detached `ark-lsp`
3. pane-side `arkbridge`

`Target Lens` adds a fourth conceptual layer:

4. project intelligence

This is not a new long-running daemon by default. It is a set of indexed,
cached, and bridge-hydrated project models owned primarily by `ark-lsp-core`.
The plugin presents the model, and `arkbridge` hydrates runtime/cache facts that
cannot be known statically.

The resulting architecture is:

- **Plugin layer**: commands, pickers, quickfix/log views, progress reporting,
  and user-triggered pipeline actions
- **LSP layer**: target-aware parsing, symbol resolution, completions, hover,
  definitions, references, diagnostics, and code actions
- **Session bridge layer**: trusted local execution of `{targets}` queries and
  selected project-scoped actions inside the managed R session
- **Project intelligence layer**: the merged static/dynamic target model used
  by the LSP and bridge-backed features

This layer must sit at the same boundary as the existing session bridge. It
must not scrape tmux text or infer pipeline state from console output.

### Project Model

`ark-lsp-core` should maintain a target project model per workspace root:

- project root and configured targets script path, defaulting to `_targets.R`
  and honoring `_targets.yaml`, `TAR_CONFIG`, and `TAR_PROJECT` where practical
- target store path, including non-default `tar_config_set(store = ...)` or
  equivalent detected configuration when available
- target declarations found statically in the configured targets script,
  `_target_pipelines/`, and other files reached by `tar_source()` / `source()`
  where practical
- package attach context from top-level `library()` / `require()` calls and
  `tar_option_set(packages = ...)` in the configured targets script
- manifest targets from `targets::tar_manifest()`
- graph edges from `targets::tar_network(targets_only = TRUE)` or an
  equivalent bridge-owned query
- cache metadata from `targets::tar_meta()`
- lightweight object metadata for cached targets, such as class, type,
  dimensions, names, column names, and top-level member names
- stale/error/warning status
- source ranges for static declarations and references

The model is deliberately two-tiered:

- **Static tier**: cheap and always available from open files and workspace
  indexing. It powers immediate completion, definitions, references, and
  diagnostics without needing the R session.
- **Dynamic tier**: bridge-hydrated data from the real project environment. It
  powers graph truth, cache status, target metadata, and actions that require
  `{targets}` itself.

The dynamic tier must refine the static model, not block it. Opening a project
must not wait for `targets::tar_manifest()` or cache inspection before normal R
language features become usable.

When a local `{targets}` store is already present, Ark may hydrate the picker
from the store's manifest/progress metadata instead of recomputing the manifest
in R. That cache path must stay generic: use `{targets}`-owned metadata, reject
it when discovered target source files are newer, and keep source provenance as
best-effort for dynamically generated targets. Generated or derived target names
should still be selectable, but their preview should point back to the static
generator declaration when Ark can identify one.

### Static Indexing Requirements

The static indexer should recognize at least:

- the configured targets script, defaulting to `_targets.R`
- files loaded with `tar_source()`
- simple `source()` calls from the configured targets script
- conventional `_target_pipelines/*.R` files
- direct `tar_target(name, command, ...)` declarations
- namespace-qualified declarations such as `targets::tar_target(...)`
- `tarchetypes::tar_render(name, path, ...)`
- calls that return lists of `tar_target()` objects when the target name itself
  is still syntactically present

Static analysis should be conservative. If a target is generated dynamically by
a factory and no reliable source range exists, Ark should still surface the
manifest target but mark the definition as dynamic or manifest-only instead of
pretending there is a precise source location.

Workspace discovery runs after LSP initialization and never delays open-buffer
language features. Initial indexing, reference searches, and directories named
by targets source calls share one ignore-aware traversal policy: honor
`.gitignore`, `.ignore`, repository excludes, and global Git ignores; never
follow directory symlinks; and skip `.git`, `.Rproj.user`, `node_modules`,
`revdep`, `renv`, and `target`. Workspace discovery indexes only `.r` and `.R`
files, while an explicitly named individual targets source file remains eligible
even when its containing directory is ignored.

Each background scan has a process-unique generation. Workspace-folder changes
invalidate older discovery and queued-index results, remove entries owned only
by removed roots, and rescan the active roots. A stale scan must never replace
current `WorldState`. Clients that support standard LSP work-done progress
receive an indexing start and finish notification; structured logs record the
generation, duration, root count, file count, and traversal-error count.

### Bridge Requirements

`arkbridge` should gain a small `{targets}` request family. Candidate requests:

- `targets_project_info`: resolve active project root, target script, store, and
  whether `{targets}` is installed
- `targets_manifest`: return target names, commands, descriptions where
  available, patterns, and declared formats
- `targets_network`: return upstream/downstream edges
- `targets_meta`: return cache status, timestamps, errors, warnings, runtime,
  bytes, and path-like metadata
- `targets_object_meta`: return bounded object metadata for one target without
  eagerly materializing large payloads unless allowed by config
- `targets_view_open`: read one exact target name from the resolved project
  store and open an ArkView session without evaluating a free-form expression;
  the Neovim-facing custom request is `ark/internal/targetsViewOpen`
- `targets_action`: run approved project-scoped actions such as make,
  invalidate, or downstream make against explicit target names

Bridge requests must be project-scoped and side-effect aware:

- read-only queries should be safe to run automatically after debounce
- build, invalidate, and load actions require explicit user commands or code
  actions
- load actions are editor execution actions: Ark should send
  `targets::tar_load(...)` to the managed pane so objects are bound in the
  pane's active evaluation context, rather than evaluating `tar_load()` inside a
  bridge request frame
- commands must pass explicit `names = ...` rather than fuzzy strings unless the
  UI has already resolved the exact set of targets
- long-running actions should stream progress or expose a log path, but Ark
  should not parse the interactive console as the source of truth
- target object inspection must have size/time limits and should degrade to
  status-only metadata when an object is too expensive to inspect

The managed R session remains the canonical runtime authority for build, load,
invalidate, and other state-changing actions because it has the right
`.Renviron`, `renv`, package library, project working directory, and local data
mounts. Read-only target ArkView is the exception: it may use a short-lived
project-scoped worker when the request supplies explicit root, script, store,
and target identity, so opening a cached target does not force a managed pane.

### LSP Feature Integration

Target intelligence should be exposed through normal LSP features where
possible:

- completion: target names, target-aware arguments, cached-object members
- definition: target reference to declaration source range, while ordinary R
  symbols inside target commands, such as a function call in `tar_target()`,
  still resolve as normal R definitions
- references: target declaration/reference search
- hover: merged static/dynamic target summary
- document symbols: target nodes and pipeline sections
- workspace symbols: target names with project/file labels
- code actions: build/invalidate/load/show graph/open log
- diagnostics: unknown target references, impossible static definitions, and
  optionally stale/failed target state

Ark-native custom requests may be added for UI surfaces that are not naturally
LSP-shaped, such as target graph exploration, target action progress, and rich
target status panes. Keep custom methods Ark-native, for example under an
`ark/targets/*` namespace.

### Plugin Surface

The plugin should present target intelligence without creating a competing
pipeline runner UI.

Expected commands:

- `:ArkTargets`
- `:ArkTargetPick`
- `:ArkTargetAcquire`
- `:ArkTargetActive`
- `:ArkTargetGraph`
- `:ArkTargetBuild`
- `:ArkTargetBuildPick`
- `:ArkTargetBuildActive`
- `:ArkTargetBuildDownstream`
- `:ArkTargetBuildDownstreamPick`
- `:ArkTargetInvalidate`
- `:ArkTargetInvalidatePick`
- `:ArkTargetLoad`
- `:ArkTargetLoadPick`
- `:ArkTargetLoadActive`
- `:ArkTargetLog`
- `:ArkTargetStatus`
- `:ArkTargetView`

The commands may use Snacks pickers when available, but the canonical operation
should remain available through LSP code actions and direct commands. Pickers
for build, load, and invalidate must get their initial target list from local
static declarations in under 1 second, then show a two-pane target list plus
creation preview. Commands should use exact target identities supplied by Ark's
static or dynamic target model rather than shelling out to fuzzy text matching.
User-facing build, load, and invalidate commands should dispatch their bridge
action asynchronously and notify on completion so Neovim remains responsive
while the managed R session works. Target invalidation should call the
idempotent tidyselect-safe invalidate path immediately, without doing metadata
or manifest preflight before the invalidation request.
The optional keymap preset and managed REPL buffers should expose `<leader>tv`
as the default target ArkView route, using the picker to open the selected
target through the direct target-store backend. Compatibility calls that use a
simple `targets::tar_read(name = ...)` ArkView expression should be routed to
the same backend instead of forcing the managed R pane.

### Cache And Invalidation

Target project state should be cached with explicit invalidation:

- buffer edits invalidate static declarations and references for that document
- writes to the configured targets script or sourced pipeline files invalidate
  the static project target index
- changes under the target store invalidate dynamic metadata
- a successful build/invalidate action invalidates affected target metadata and
  graph status
- a bridge session restart invalidates dynamic data but should preserve static
  indexing

Expensive dynamic refresh should be debounced and cancelable. The default
startup path should only schedule target hydration after normal LSP/session
readiness, unless the user explicitly runs a target command.

### Non-Goals

`Target Lens` does not:

- reimplement `{targets}`
- replace `snipe`, `stop`, or project-specific helper packages
- make Ark responsible for remote/HPC pipeline orchestration
- run arbitrary target builds automatically
- parse tmux pane output as target state
- require all target factories to have perfect static source locations
- make stale target diagnostics noisy by default

### Acceptance Criteria

`v1.1 Target Lens` is shippable when:

- target-name completion works in R scripts and literate R documents
- go-to-definition works for statically declared targets across the configured
  targets script and sourced pipeline files
- hover shows a useful merged static/dynamic target summary
- `tar_read()` / `tar_load()` references are not reported as unknown symbols
  when the target exists
- cached-object member or column completion works for at least data frames,
  data.tables, lists, and rendered target objects when inspection is safe
- `<leader>tv`, `:ArkTargetView`, and simple `targets::tar_read(name = ...)`
  ArkView calls open cached targets directly from the target store without
  starting the managed R pane
- build, invalidate, load, status, graph, and log actions operate on exact
  target identities
- generated/dynamic targets degrade gracefully as manifest-only targets
- opening a target project does not regress current Ark startup timing in the
  no-target-command path

### Verification Expectations For v1.1

Verification should use a small repo-owned toy `{targets}` project plus at
least one real-world-style split-pipeline fixture.

Required coverage:

- Rust unit tests for static target extraction and reference classification
- request-level LSP tests for completion, definition, references, hover, and
  diagnostics
- bridge tests for manifest, network, metadata, object metadata, and bounded
  failure behavior
- headless Neovim tests for commands and code actions
- tmux-backed E2E tests that prove live bridge hydration and exact target
  actions
- R Markdown / Quarto tests where target references occur inside fenced chunks
  and inline `` `r ...` `` expressions

## Open Work After This Tranche

The detached product boundary is now Cargo-enforced: `ark-lsp` cannot construct
an attached runtime mode and does not compile the optional `Console` / attached
R-thread host hooks. The retained upstream `ark` host explicitly enables those
compatibility adapters.

Continuing to reduce inherited kernel/Jupyter source remains legitimate
maintenance work, but it is not required for the Neovim product boundary; those
crates are excluded from default product builds and release artifacts.

## Completion Architecture

Completion intent for Ark filetypes is owned by Rust. Literate-R normalization,
semantic region classification, source precedence, intentional suppression, and
static/live merge policy are server responsibilities.

The canonical state model is
`crates/ark-lsp-core/src/lsp/completions/plan.rs::CompletionPlan`. It represents
exactly three outcomes:

- `HandledEmpty`: Ark owns the context and intentionally returns no items
- `Unique`: one exclusive source or bridge request owns the context
- `Composite`: multiple compatible sources or bridge requests may contribute

Static source planning and live bridge request planning use that same generic
model with different payloads. Static payloads name the existing `unique` and
`composite` source families; bridge payloads describe execution requests. Bridge
transport remains an execution detail and does not define a second completion
state machine.

`handle_completion()` owns the detached product sequence: static target and
pre-bridge contexts, path preemption, live bridge planning, post-bridge string
fallback, then mergeable static sources. A handled empty bridge plan remains
handled, so attached-runtime fallbacks cannot run afterward.

For literate documents, fenced R, inline `` `r ...` ``, frontmatter, and prose
are classified by the server document/context layer. Comparison strings,
package strings, argument strings, string subsets, namespace access, extractors,
calls, pipes, and generic symbols are likewise decided in Rust.

The Blink adapter is editor integration only:

- register Blink's normal LSP provider as the sole automatic Ark source
- normalize cursor positions and forward advertised trigger characters after
  delimiter-pair insertion
- discard Blink's stale trigger-character cache before a new keyword request,
  without inspecting buffer text
- coordinate menu, documentation, hover, and signature-help windows
- render Ark target completion items with their product-specific kind label

Startup recovery asks Blink/LSP for a keyword completion and lets Blink's
minimum-length policy plus the Rust planner decide applicability. The adapter
contains no regex or source-text parser for completion semantics.

The retained attached kernel compatibility path uses the shared static source
planner when its Cargo feature is enabled. It is not compiled into the detached
Neovim product.

### Completion Invariants

- Ark filetypes use Blink's standard `lsp` implementation, not a custom
  completion engine.
- `.Rmd`, `.qmd`, and `quarto` semantics are decided server-side.
- Blink does not decide whether a trigger belongs to subset, string,
  frontmatter, inline-R, package-call, or prose completion.
- Runtime completion may return an intentionally handled empty set without
  falling through to unrelated sources.
- Static and live execution plans share the same handled/unique/composite state
  model and preserve the documented precedence tests.

### Verification Expectations

Completion changes must be proven at both levels:

- planner and precedence logic: Rust unit tests
- request semantics: direct `textDocument/completion` tests
- real interactive behavior: tmux-backed or real-config TUI tests that prove
  Blink-visible behavior while typing

High-value regression coverage for this tranche includes:

- extractor completion
- subset and string-subset completion
- comparison-string completion
- path-string completion, including slash-triggered paths inside quoted strings
- package-string and argument-string completion
- frontmatter output completion
- inline `` `r ` `` empty-prefix completion
- prose `.Rmd` cases where non-semantic completion must not leave stale Blink
  UI behind

## Supportability And Product-State Contract

Ark exposes one user-facing state classification through `:Ark status`:

- `live_ready`
- `static_starting`
- `static_only`
- `live_degraded`
- `update_in_progress`
- `restart_required`
- `unsupported`

Static language features remain the supported floor in every state except an
unsupported configuration/environment. Persistent warnings are transition
notices, not the source of truth; identical warnings are deduplicated and the
durable state plus recovery action remains available through status, health,
and the support report.

Observed readiness takes precedence over startup policy: a manually started
session with both bridge and REPL ready is `live_ready` even when
`auto_start_pane = false`; that option controls automatic startup only.

Configuration is validated before setup mutates editor state. Unknown keys,
wrong types, and unsupported enum values fail with `E_CONFIG`, the exact dotted
path, and accepted values. Component and bridge errors preserve their existing
machine-readable `E_*` codes and map to stable user actions documented by the
plugin error catalog.

`:checkhealth ark` is read-only and must not start a managed R session. It
validates released component compatibility, supported Neovim/R/platform facts,
backend requirements, `jsonlite`, executable discovery, an efficient Linux
workspace file-watch backend when file watching is enabled, writable
install/state locations, and incompatible ready status files. `:Ark report`
works before setup and in degraded mode. It opens a local preview and selects
only normalized component/state/health facts; it does not include auth tokens,
cookies, arbitrary environment values, source contents, R values, or unrelated
logs.

Native `:help ark` is the complete command/configuration reference. Inherited
Positron and Jupyter documentation is isolated under `doc/upstream/` and is not
part of the supported Neovim product documentation.

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
  config rather than maintaining a second minimal setup; the
  [scripts/docker-readme-test.sh](/home/marine/repos/ark.nvim/scripts/docker-readme-test.sh)
  wrapper should keep an auto mode that rebuilds stale images before launching
  the harness
- ambient user-config smoke remains optional via `--init ~/.config/nvim/init.lua`

The product test inventory is `tests/test-manifest.json`. It is the single
source of truth for Lua test tier, ownership, dependencies, protected contract,
serial execution, runtime expectation, flake policy, and shared-session use.
`just verify-product` combines the pure `unit` and deterministic `fast` tiers
with the product's Rust and packaging contracts. `serial-integration`,
prepared-fixture `full-tui`, `performance`, and `soak` remain deeper local
gates, and `just verify` is the canonical pre-release suite. Tests that declare
no tmux dependency must run without creating a tmux server.

Full-TUI verification uses the pinned repo-owned fixture described by
`tests/e2e/fixture-lock.json`; test execution must not clone plugins. Performance
governance records schema-versioned samples for named user-visible events and
checks repeated p50, p95, and worst-case results against both reviewed rolling
baselines and versioned hard budgets. Results are reviewed on the canonical
development machine. Raw samples, summaries, transcripts, and failure logs are
retained under the path printed by `just benchmark`; every failed run must
print those retained paths.

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

The durable architecture, release, and verification contracts for that
hardening phase live in this specification and `docs/testing.md`. Deferred
upstream state-model work remains documented in
`crates/ark-lsp-core/UPSTREAM_STATE_MODEL.md`.
