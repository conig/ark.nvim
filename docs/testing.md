# Product test system

Ark keeps one machine-readable inventory in `tests/test-manifest.json`. Every
Lua test resolves to a tier, protected contract, owner, dependencies, expected
runtime, flake policy, shared-session declaration, and cheapest valid layer.
`scripts/test-manifest.py validate` fails when a Lua file is not classified.

The authoritative routine product gate is:

```sh
just verify-product
```

It covers product Rust, package, installer, and focused Neovim contracts. The
manifest's `required` selection contains pure Lua unit tests and deterministic
component/product smokes. Tests whose manifest dependencies omit tmux run
without creating a tmux server. The deeper `serial-integration`, `full-tui`,
`performance`, and `soak` tiers remain serial within a runner. The canonical
full pre-release command is:

```sh
just verify
```

Use `just verify-upstream-compat` when retained workspace crates may have been
affected.

Full-TUI tests use `tests/e2e/init.lua`, not the user's configuration. Prepare
its exact Blink and Snacks revisions before assertions with:

```sh
scripts/prepare-e2e-fixture.py --download
```

The test runner never downloads plugins. It validates the prepared cache and
fails with the preparation command if a dependency is missing or stale.

## Package quality gate

`packages/arkbridge/tests/testthat` covers IPC dispatch and error schemas,
ArkView filtering and paging, help rendering, static targets behavior and action
validation, and package metadata/install planning. `scripts/check-arkbridge.sh`
runs those tests through `R CMD check --no-manual` and requires zero warnings
and zero notes.

## Performance results

Run repeated local benchmarks with:

```sh
just benchmark
```

Each test appends schema-versioned NDJSON samples. The summary records p50, p95,
and worst-case latency by user-visible event and rejects missing, malformed, or
under-sampled results. Hard budgets, sample counts, fixture assumptions, and
noise tolerances live in `tests/performance-budgets.json`. The runner retains
the raw samples, summary, and transcript under `artifacts/performance/` and
prints their paths on both success and failure.

`tests/performance-baseline.json` is the reviewed rolling baseline. Update it
only from representative reviewed results on the canonical development machine
after investigating the change; do not update it merely to make a regression
pass. For startup/indexing changes, collect ten serial cold-start samples before
and after the change. The summary enforces both hard budgets and the baseline
plus each event's declared noise tolerance.

Retries are evidence only. The local runner never converts a failed semantic
assertion into a pass. Failed E2Es retain their isolated temporary directory
and log and print both paths, while successful runs remove them unless
`--keep-artifacts` is requested.

## Reviewed post-sync hardening baseline

The 2026-07-15 baseline covers the tree at `e157fc79` plus the subsequent
baseline-record update, after merging upstream `a00853de` in `ca1d19d0`. It was
collected on the canonical Arch Linux development machine with Rust/Cargo 1.97,
Neovim 0.12.4, R 4.6.1, tmux 3.7b, and ripgrep 15.1.

- `just verify-product` passed, including 507 active `ark-lsp-core` unit tests
  with one manual benchmark ignored and an `R CMD check` with zero warnings or
  notes.
- `just verify-upstream-compat` passed every retained workspace, integration,
  and doctest target, including the Amalthea integration path.
- `just verify` passed all 249 manifest-classified E2Es across the unit, fast,
  serial-integration, full-TUI, performance, and soak tiers.
- `just benchmark` passed all hard and rolling-baseline limits across 503
  samples. The reviewed p95 values are stored in
  `tests/performance-baseline.json`.

Ten serial samples on the 10,000-file ignored-workspace fixture reduced LSP
initialization p95 from 179.362 ms at `a04e5a78` to 11.498 ms, a 93.6%
improvement. Cross-file definition lookup succeeded after background indexing
in every sample. Ten serial managed-session cold starts reduced p95 from 390 ms
to 368 ms and remained well below the 1200 ms hard budget.

The final gate exposed two hardening-test defects before passing: a standard
mutex guard crossing an async test await, and a target-completion test that
assumed synchronous workspace indexing. The first now uses a synchronous test
runtime boundary; the second waits only for its workspace-wide initial result.
Both focused regressions and the complete suite passed afterward. The earlier
2026-07-10 rolling values remain available in Git history as a historical
baseline rather than the active performance policy.
