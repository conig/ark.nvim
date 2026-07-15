# Upstream LSP State Model Decision

Decision date: 2026-06-30; reaffirmed 2026-07-15

## Decision

Do not port upstream's `OpenFile` / `OakDatabase` / `oak_scan` LSP state model
as part of the upstream-sync-ease cleanup.

The fork should keep the current `Document` plus fork-owned indexer model until
the port is planned as its own behavior-preserving refactor. The shared
`ark-lsp-core` crate extraction already removes the recurring path-shared source
conflict without changing the active Neovim runtime model.

The 2026-07-15 sync through upstream `a00853de` retained the upgrade to Salsa
0.27.2 and upstream changes to Oak workspace inputs, package resolution,
definition/reference search, invalidation, and scan scheduling. Those changes
do not remove the fork-specific migration risks below. The current pre-alpha
hardening work is therefore limited to improving the existing walk policy,
background scan generations, and workspace-folder lifecycle; it must not
migrate the semantic state model or remove the fork-owned indexer.

## Evidence

Current upstream `upstream/main` stores editor buffers as `OpenFile` keyed by
normalized `aether_path::FilePath`, keeps an `OakDatabase` in `WorldState`, and
dispatches workspace scanning through `oak_scan`.

Current `ark.nvim` still stores editor buffers as `Document` keyed by wire
`Url`. It also carries detached-session fields in `WorldState`, including
bridge config, bootstrap generation, hydration status, and runtime mode. Those
fields are part of the detached stdio Neovim product path and have no upstream
equivalent.

Current `ark.nvim` indexing still has product-specific behavior that must be
preserved during any future port:

- detached scratch workspaces rooted at the OS temp directory do not trigger a
  broad initial scan
- detached session hydration is driven by `ark/updateSession` notifications and
  document events, not by embedded-R startup
- target-related companion files are indexed so definitions and completions work
  across `_targets.R` and sourced target scripts
- bridge-owned runtime completion contexts must remain handled even when they
  return zero items, so detached fallback paths do not call local embedded-R
  code

## Future Port Plan

A future port should be a dedicated refactor with red/green coverage, not a
merge-conflict resolution shortcut.

Recommended order:

1. Port upstream `OpenFile` and content-change handling into `ark-lsp-core`
   while preserving wire `Url` output for Neovim.
2. Add `OakDatabase` to the shared `WorldState` without removing detached
   bridge/session fields.
3. Route disk workspace scans through `oak_scan` only after reproducing current
   target companion indexing and temp-root skip behavior.
4. Move definitions/references/diagnostics to the database-backed path one
   feature at a time.
5. Remove the fork-owned indexer only after focused E2Es prove parity.

Manual upstream review files during syncs:

- `crates/ark/src/lsp/state.rs`
- `crates/ark/src/lsp/open_file.rs`
- `crates/ark/src/lsp/main_loop.rs`
- `crates/ark/src/lsp/state_handlers.rs`
- `crates/oak_scan/**`
- `crates/oak_db/**`
- `crates/oak_ide/**`

Focused verification for any future port:

```sh
cargo check -p ark-lsp -p ark
cargo test -p oak_db -p oak_scan -p oak_ide -p ark-lsp-core --lib
./scripts/run-e2e-test.sh --init NONE tests/e2e/base_diagnostics.lua tests/e2e/detached_parity.lua tests/e2e/definition_open_buffer_index.lua tests/e2e/definition_new_targets_file_index.lua
./scripts/run-e2e-test.sh --init NONE tests/e2e/comparison_string_completion.lua tests/e2e/subset_completion.lua tests/e2e/completion_resolve.lua
```
