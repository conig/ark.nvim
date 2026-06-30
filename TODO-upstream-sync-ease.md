# TODO: Reduce avoidable upstream sync drift

Created after the 2026-06-30 upstream sync on `sync/upstream-2026-06-30`.

Status after implementation:

- TODO 1 implemented: `crates/ark-lsp-core` is now a real Cargo crate, the
  workspace is back to `members = ["crates/*"]`, and host crates re-export the
  shared LSP implementation instead of using `#[path]` imports.
- TODO 2 implemented: `backend.rs`, `main_loop.rs`, and `state_handlers.rs`
  are shared in `ark-lsp-core`; the attached-only Amalthea wrapper and runtime
  hooks remain in `crates/ark/src/lsp/`.
- TODO 3 resolved by documented decision: keep the current `Document` and
  fork-owned indexer model for now, with future port guidance in
  `crates/ark-lsp-core/UPSTREAM_STATE_MODEL.md`.
- TODO 4 implemented: test workflow display names now match upstream again;
  upstream release workflow deletion remains an intentional product divergence.

This file is for follow-up work that should make future syncs from
`posit-dev/ark` easier without undoing the Neovim product boundary. Treat these
as TODOs with discovery notes, not as pre-decided implementations. If the current
tree has moved, re-run the discovery commands and update the plan before editing.

## Ground Rules

- Preserve the active `ark.nvim` product boundary from `AGENTS.md` and `SPEC.md`.
  The Neovim plugin, detached `ark-lsp`, tmux/session management, `arkbridge`,
  and focused E2E harnesses are intentional fork surface.
- Do not reintroduce upstream kernel/DAP/Jupyter/Positron test harnesses merely
  to reduce diff size. They do not verify the current Neovim product surface.
- Do not hide upstream LSP changes behind broad merge rules. Upstream
  `crates/ark/src/lsp/...` still contains language-server work that this fork
  should review and often port.
- Prefer changes that reduce duplicated source-of-truth code or recurring
  mechanical conflicts. Avoid churn that only makes the diff look smaller.
- For each TODO below, verify both `ark` and `ark-lsp` where relevant. A change
  that compiles only one host crate is not complete.

Useful baseline commands:

```sh
git status --short --branch
git diff --stat upstream/main...HEAD
git diff --name-status upstream/main...HEAD
git rev-list --left-right --count HEAD...upstream/main
```

Recommended focused verification after LSP-shape changes:

```sh
cargo metadata --no-deps --format-version 1
cargo check -p ark-lsp -p ark
cargo check --workspace
cargo +nightly fmt --all -- --check
cargo test -p ark-lsp --lib
./scripts/run-e2e-test.sh --init NONE tests/e2e/base_diagnostics.lua tests/e2e/detached_parity.lua
```

Broaden the E2E set when touching completion, bridge hydration, indexing, or
session-specific behavior.

## TODO 1: Promote `ark-lsp-core` from path-shared source tree to a real crate

### Goal

Make the shared LSP implementation compile as a normal Cargo crate, then let
`ark` and `ark-lsp` depend on it instead of importing dozens of files with
`#[path = ...]`.

This is the highest-leverage cleanup because future upstream syncs currently
have to reconcile upstream's in-crate `crates/ark/src/lsp/...` layout with this
fork's path-shared `crates/ark-lsp-core/src/lsp/...` layout.

### Current Discovery

- `crates/ark-lsp-core` currently contains only `README.md` at shallow depth;
  it has no `Cargo.toml`, so it is not a Cargo package.
- The top-level workspace uses explicit members in `Cargo.toml` instead of
  upstream's `members = ["crates/*"]`. The historical reason was that
  `crates/ark-lsp-core` is not a crate.
- Both host modules manually point at shared files:
  - `crates/ark/src/lsp.rs`
  - `crates/ark-lsp/src/lsp.rs`
- `crates/ark-lsp-core/README.md` already says the intended next step is to
  shrink host hooks until the source tree can become a real shared library.
- There is already a small real support crate:
  `crates/ark-lsp-support`. It currently contains helper types and shared
  notifications/traits, but not the full LSP implementation.

Discovery commands used:

```sh
find crates/ark-lsp-core -maxdepth 2 -type f | sort
sed -n '1,120p' crates/ark-lsp-core/README.md
sed -n '1,120p' crates/ark/src/lsp.rs
sed -n '1,120p' crates/ark-lsp/src/lsp.rs
sed -n '1,80p' crates/ark-lsp-support/Cargo.toml
sed -n '10,38p' Cargo.toml
```

Known host-crate hooks still referenced from the shared tree include:

- `crate::console`
- `crate::r_task`
- `crate::analysis`
- `crate::fixtures`
- `crate::url`
- `crate::treesitter`

Discovery command:

```sh
rg -n 'crate::(console|r_task|analysis|fixtures|url|treesitter)' crates/ark-lsp-core/src/lsp -g '*.rs'
```

### Possible Implementation Routes

Do not assume one route is definitely correct before attempting the work.
Evaluate the current tree first.

Option A: turn `crates/ark-lsp-core` into the real crate and keep
`ark-lsp-support` as a small support crate.

- Add `crates/ark-lsp-core/Cargo.toml`.
- Move or expose a normal `src/lib.rs` for the shared LSP module tree.
- Replace `#[path]` imports in both host crates with imports from the new crate.
- Convert host-only dependencies into explicit traits, callbacks, or small
  adapter modules.
- Keep adapter files in host crates where they truly depend on attached vs
  detached runtime behavior.

Option B: expand `ark-lsp-support` into the real shared crate and retire or
rename `ark-lsp-core`.

- This may reduce crate count, but check whether the name `ark-lsp-support`
  would become misleading once it owns the main implementation.
- Avoid a rename-only diff unless it materially simplifies imports and future
  syncs.

Option C: incremental extraction.

- First move one low-risk hook family, such as `treesitter` helpers or `url`
  helpers, into a real shared crate.
- Then repeat until the remaining `#[path]` tree is thin enough to move safely.
- This is slower, but may be safer if a direct crate extraction creates too many
  circular dependencies.

### Things To Watch

- `ark-lsp` currently re-exports several `ark` modules in
  `crates/ark-lsp/src/lib.rs`. That is a sign of coupling, not necessarily a
  permanent design.
- Some shared-code test modules use `crate::fixtures` and `crate::r_task`.
  Test-only dependencies may need a different shape from production
  dependencies.
- `Console` is not the same concept in the attached and detached crates.
  Avoid creating a fake common console if a small capability trait is clearer.
- Do not break snapshot resolution. The current path-shared layout also carries
  shared insta snapshots.

### Acceptance Criteria

- `crates/ark-lsp-core` is either a real crate or the repo has a documented,
  narrower intermediate step that measurably removes host hooks.
- The number of `#[path = "../../ark-lsp-core/..."]` imports in host `lsp.rs`
  files is reduced or eliminated.
- The workspace can preferably return to upstream-style `members = ["crates/*"]`
  if no non-crate directory remains under `crates/`.
- Both `ark` and `ark-lsp` compile and keep the existing focused E2Es green.

Suggested verification:

```sh
cargo metadata --no-deps --format-version 1
cargo check -p ark-lsp -p ark
cargo test -p ark-lsp --lib
cargo test -p ark --lib --no-run
./scripts/run-e2e-test.sh --init NONE tests/e2e/static_lsp_surface.lua tests/e2e/base_diagnostics.lua tests/e2e/detached_parity.lua
```

## TODO 2: Deduplicate the near-identical `state_handlers.rs` host adapters

### Goal

Reduce drift between:

- `crates/ark/src/lsp/state_handlers.rs`
- `crates/ark-lsp/src/lsp/state_handlers.rs`

These files are currently almost identical. Keeping two copies means upstream
handler changes and local bug fixes must be reconciled twice.

### Current Discovery

The current diff is small relative to file size. The main known differences are:

- `ark-lsp` skips initial indexing for a detached scratch workspace rooted
  directly at the OS temp directory.
- `ark-lsp` omits an `index_update()` call on `did_open`.
- The attached `ark` path sends `ConsoleNotification::DidChangeDocument` with
  `aether_path::FilePath`; detached `ark-lsp` sends a `String`.

Discovery commands:

```sh
wc -l crates/ark/src/lsp/state_handlers.rs crates/ark-lsp/src/lsp/state_handlers.rs
diff -u crates/ark/src/lsp/state_handlers.rs crates/ark-lsp/src/lsp/state_handlers.rs | rg -n '^@@|^[+-][^+-]'
rg -n 'enum ConsoleNotification|DidChangeDocument|console_notification_tx' crates/ark/src crates/ark-lsp/src crates/ark-lsp-core/src/lsp -g '*.rs'
```

Related details:

- Attached console notification type:
  `crates/ark/src/console/console_repl.rs`
- Detached console stub:
  `crates/ark-lsp/src/console.rs`
- The temp-root skip is likely still important for detached `/tmp` scratch
  workspaces. Do not remove it without reproducing the old failure mode.

### Possible Implementation Routes

Option A: move most of `state_handlers.rs` into shared code and provide a small
host policy object.

Possible policy hooks:

- server name/version string for initialize result
- completion trigger list if attached and detached really differ
- whether to skip temp-root workspace indexing
- whether `did_open` should queue an index update
- how to send console document-change notifications

Option B: keep files separate but extract the repeated helpers first.

Start with low-risk shared functions:

- workspace URI collection and root detection
- detached session hydration helpers if they stay identical
- session update/bootstrap status bookkeeping
- initialize capability construction if it can be parameterized cleanly

Option C: defer this until TODO 1 creates a real shared crate.

This is reasonable if the necessary abstractions would be awkward in the
current path-shared module setup.

### Things To Watch

- Do not paper over real attached/detached behavior differences. If a branch is
  product-specific, keep it explicit.
- Avoid a giant generic `HostAdapter` with many unrelated methods. Prefer a few
  narrow hooks or data structs.
- The detached temp-root skip is a concrete bug fix from earlier sync work.
  Preserve the behavior unless a better workspace-root model makes it obsolete.
- If completion trigger characters differ, check Blink/full-config behavior
  before normalizing them.

### Acceptance Criteria

- Handler logic that is genuinely common lives in one place.
- The remaining host-local code is small and obviously product-specific.
- The diff between the two host files is reduced substantially, or a comment
  documents why a specific difference is intentional.
- Existing focused E2Es for detached startup, diagnostics, and completion still
  pass.

Suggested verification:

```sh
cargo check -p ark-lsp -p ark
cargo test -p ark-lsp --lib state_handlers
./scripts/run-e2e-test.sh --init NONE tests/e2e/base_diagnostics.lua tests/e2e/detached_parity.lua tests/e2e/home_directory_buffer_uses_scratch_workspace.lua
```

If trigger characters or completion capabilities change, also run:

```sh
./scripts/run-e2e-test.sh --init NONE tests/e2e/comparison_string_completion.lua tests/e2e/subset_completion.lua tests/e2e/library_completion.lua
```

## TODO 3: Evaluate a deliberate port to upstream's `OpenFile` / `OakDatabase` / `oak_scan` LSP state model

### Goal

Decide whether and how the active Neovim LSP path should adopt upstream's newer
LSP state architecture. If the answer is yes, port it deliberately with
regression coverage rather than resolving future sync conflicts by repeatedly
restoring the older fork-owned state model.

This is larger and riskier than TODO 1 or TODO 2. It should be treated as a
design/refactor task, not housekeeping.

### Current Discovery

During the 2026-06-30 sync, upstream had moved more LSP logic into:

- `OpenFile`
- `aether_path::FilePath`
- `OakDatabase`
- `oak_scan`
- updated `oak_db` / `oak_ide` shapes

The fork preserved its active Neovim LSP boundary and kept upstream's low-level
crate updates around it. That was the right sync decision, but it leaves a
future integration decision open.

Relevant upstream files to compare:

```sh
git show upstream/main:crates/ark/src/lsp/state.rs
git show upstream/main:crates/ark/src/lsp/open_file.rs
git show upstream/main:crates/ark/src/lsp/main_loop.rs
git show upstream/main:crates/ark/src/lsp/state_handlers.rs
git ls-tree -r --name-only upstream/main crates/ark/src/lsp crates/oak_scan crates/oak_db
```

Relevant current fork files:

- `crates/ark-lsp-core/src/lsp/state.rs`
- `crates/ark-lsp-core/src/lsp/document.rs`
- `crates/ark-lsp-core/src/lsp/indexer.rs`
- `crates/ark/src/lsp/main_loop.rs`
- `crates/ark-lsp/src/lsp/main_loop.rs`
- `crates/ark/src/lsp/state_handlers.rs`
- `crates/ark-lsp/src/lsp/state_handlers.rs`
- `crates/ark-lsp-core/src/lsp/session_bridge.rs`

Current fork state still centers on `Document` and its own indexing path. The
upstream state model stores editor buffers as `OpenFile` keyed by normalized
`FilePath`, keeps a Salsa `OakDatabase` in `WorldState`, and routes scanning
through `oak_scan`.

### Initial Questions For The Future Agent

Answer these with code evidence before editing broadly:

- Which current fork features depend on the old `Document` shape rather than a
  file-backed database entry?
- Which detached bridge features need live-session state outside upstream's
  `WorldState`?
- Can `session_bridge` operate with upstream `OpenFile` and `OakDatabase`
  primitives without turning runtime-aware completion into attached-R behavior?
- Does `oak_scan` already cover the fork's current index update behavior,
  including targets-related companion files and scratch buffers?
- Which current E2Es prove the behavior that upstream's model must preserve?

### Possible Implementation Routes

Option A: port the shared state model first, keep host adapters mostly intact.

- Introduce `OakDatabase` and normalized `FilePath` keys into the shared state.
- Keep detached session fields and bridge hydration in the fork's `WorldState`
  until a better shape is clear.
- Port one handler path at a time: `did_open`, `did_change`, diagnostics,
  definition/references, workspace scanning.

Option B: port upstream `open_file.rs` and content-change handling as a smaller
first step.

- This may reduce diff and de-risk later `oak_scan` adoption.
- Check whether current literate-R normalization and line-index behavior match
  upstream's assumptions.

Option C: keep the current model but document an explicit divergence.

- This may be correct if upstream's model is too attached-kernel-oriented or
  conflicts with detached live-session behavior.
- If choosing this route, add a short design note explaining why, and make
  future syncs easier by listing the upstream files that should be reviewed
  manually instead of merged mechanically.

### Things To Watch

- Detached LSP must not accidentally call embedded-R paths. Bridge-owned zero
  completion results should still count as handled where the bridge owns the
  context.
- Do not regress the live session readiness split: `bridge_ready` and
  `repl_ready` are related but not interchangeable.
- Do not reintroduce upstream Jupyter/kernel event assumptions into the stdio
  Neovim path.
- Treat workspace scanning carefully. Prior failures included broad temp-root
  scans when `/tmp` looked like a workspace.
- Keep static-only fallback behavior when no live session is attached.

### Acceptance Criteria

- There is either a working port plan with passing focused tests, or a written
  decision to keep the forked model with clear sync guidance.
- If porting, behavior is preserved for:
  - detached stdio startup from Neovim
  - base diagnostics
  - detached/static parity
  - completion and completion resolve
  - definitions/references against open buffers and disk-indexed files
  - live-session completion paths that use the bridge
- Future upstream syncs should no longer require blindly choosing between two
  incompatible LSP state trees.

Suggested verification:

```sh
cargo check -p ark-lsp -p ark
cargo test -p oak_db -p oak_scan -p oak_ide -p ark-lsp --lib
./scripts/run-e2e-test.sh --init NONE tests/e2e/base_diagnostics.lua tests/e2e/detached_parity.lua tests/e2e/definition_open_buffer_index.lua tests/e2e/definition_new_targets_file_index.lua
./scripts/run-e2e-test.sh --init NONE tests/e2e/comparison_string_completion.lua tests/e2e/subset_completion.lua tests/e2e/completion_resolve.lua
```

If the change touches live bridge behavior, add focused live/tmux verification
or document a manual path before calling it complete.

## TODO 4: Decide whether local GitHub workflow branding is worth recurring merge conflicts

### Goal

Remove recurring trivial conflicts in GitHub workflow names if the local
branding does not matter enough to keep them.

This is intentionally small. Do not spend much engineering time here.

### Current Discovery

The current differences in test workflow files are only display names:

```diff
-name: "Test Ark"
+name: "Test ark.nvim"
```

and similarly for Linux, macOS, and Windows. The fork also deletes upstream
release workflows, which is probably intentional because this repository does
not ship upstream Ark releases.

Discovery commands:

```sh
git diff upstream/main...HEAD -- .github/workflows/test-linux.yml .github/workflows/test-macos.yml .github/workflows/test-windows.yml .github/workflows/test.yml
git diff --name-status upstream/main...HEAD -- '.github/workflows/*.yml' '.github/workflows/*.yaml'
```

### Possible Implementation Routes

Option A: accept upstream test workflow names.

- Rename the workflows back to upstream names.
- This removes recurring one-line conflicts at the cost of less precise branding
  in the GitHub Actions UI.

Option B: keep local names and document that this conflict is accepted.

- Add a short note near the workflow files or in this TODO if the branding is
  intentionally useful.
- Future sync agents can then resolve these conflicts quickly without revisiting
  the decision.

Option C: isolate fork-specific workflow naming in a separate wrapper.

- Only worth considering if workflow churn grows beyond names.
- Avoid making CI more complex just to preserve display text.

### Things To Watch

- Do not restore upstream release workflows unless the release strategy has
  changed. They are a separate product decision from test workflow display
  names.
- If changing workflow names, no Rust/Lua verification is needed, but YAML
  syntax should still be checked by inspection or CI.

### Acceptance Criteria

- Either local workflow names match upstream again, or the repo documents that
  the display-name drift is intentional.
- Future sync agents can resolve workflow-name conflicts without additional
  investigation.

Suggested verification:

```sh
git diff --check
git diff upstream/main...HEAD -- .github/workflows/test-linux.yml .github/workflows/test-macos.yml .github/workflows/test-windows.yml .github/workflows/test.yml
```

## Non-TODO: Keep These Divergences Unless Product Direction Changes

These areas are not pointless drift based on the current product boundary:

- `lua/ark/**`
- `plugin/ark.lua`
- `packages/arkbridge/**`
- tmux and terminal backend management
- `scripts/ark-r-launcher.sh` and related runtime scripts
- focused `tests/e2e/**` for Neovim, Blink, bridge, tmux, ArkHelp, ArkView,
  targets, and startup behavior
- removal of upstream `ark_test` and kernel/DAP integration tests that do not
  exercise the supported Neovim product surface

Future syncs should keep reviewing upstream language-analysis improvements, but
should not shrink the fork by deleting product code that upstream does not have.
