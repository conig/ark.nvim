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
- optionally attach a conservative R-family keymap preset for the recommended
  pane, send, help, ArkView, snippets, and tab workflows
- send text to the active managed R session through the configured backend
- start detached `ark-lsp`
- show visible detached `ark-lsp` rebuild progress in a floating log window,
  including cargo output, with `q` closing only the window while the build and
  follow-up LSP attach/restart continue
- relay session metadata through `ark/updateSession`
- expose a lazy-load-friendly `:Ark` dispatcher plus compatibility commands such
  as `ArkPaneStart`, `ArkTab*`, `ArkHelp`, and `ArkStatus`
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
- format ArkView display-only string cells so empty strings, boundary spaces,
  and repeated spaces remain visually distinguishable without changing raw
  export, filter, sort, or cell-copy semantics
- keep ArkView page rows encoded as row arrays even for one-column tables

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
Its completion key policy uses `Enter` or `Tab` to accept a visible Blink
completion, uses `Enter` to submit when no completion menu is visible, uses
`Alt-Enter` to insert a newline without accepting completion, and uses
`Shift-Tab` as the visible-menu bypass for inserting a literal tab without
accepting completion.
For R plotting and pipe workflows, the console also maps `<leader>\` to append
`|>` and `<leader>=` to append `+`, each opening a new editable continuation
line in the current console input.

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

The managed R session remains the canonical runtime authority because it has
the right `.Renviron`, `renv`, package library, project working directory, and
local data mounts. A separate hidden R process may be considered later only if
it can reproduce that environment without splitting the user's runtime state.

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
as the default target ArkView route, using the picker to open
`targets::tar_read(name = ...)` for the selected target.

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
- path-string completion, including slash-triggered paths inside quoted strings
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
  config rather than maintaining a second minimal setup; the
  [scripts/docker-readme-test.sh](/home/marine/repos/ark.nvim/scripts/docker-readme-test.sh)
  wrapper should keep an auto mode that rebuilds stale images before launching
  the harness
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
