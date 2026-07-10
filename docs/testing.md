# Product test system

Ark keeps one machine-readable inventory in `tests/test-manifest.json`. Every
Lua test resolves to a tier, protected contract, owner, dependencies, expected
runtime, flake policy, shared-session declaration, and cheapest valid layer.
`scripts/test-manifest.py validate` fails when a Lua file is not classified.

The required pull-request gate is:

```sh
scripts/run-full-suite.sh --skip-rust --skip-clippy --tier required
```

`required` contains pure Lua unit tests and deterministic component/product
smokes. Tests whose manifest dependencies omit tmux run without creating a tmux
server. The deeper `serial-integration`, `full-tui`, `performance`, and `soak`
tiers remain serial within a runner. The canonical pre-release command remains:

```sh
scripts/run-full-suite.sh --tier full
```

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

Run repeated benchmarks with:

```sh
scripts/run-performance-suite.sh
```

Each test appends schema-versioned NDJSON samples. The summary records p50, p95,
and worst-case latency by user-visible event and rejects missing, malformed, or
under-sampled results. Hard budgets, sample counts, fixture assumptions, and
noise tolerances live in `tests/performance-budgets.json`. Scheduled CI retains
the raw samples, summary, and transcript for 90 days.

`tests/performance-baseline.json` is the reviewed rolling baseline. Update it
only from a representative five-run scheduled artifact after investigating the
change; do not update it merely to make a regression pass. The summary enforces
both hard budgets and the baseline plus each event's declared noise tolerance.

Retries are evidence only. Neither the local runner nor CI converts a failed
semantic assertion into a pass. Failed E2Es retain their isolated temporary
directory and log, while successful runs remove them unless
`--keep-artifacts` is requested.
