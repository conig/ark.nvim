# TODO: Move `ark.nvim` from feature-rich alpha to dependable product

Created after the 2026-07-10 repository-wide maintainability, performance, and
product-readiness review.

This document turns that review into five independently assignable TODOs. The
ordering is deliberate, but it is not a mandate to implement every detail
exactly as described. Each worker should re-run the discovery commands, confirm
that the current tree still has the same shape, and choose the smallest design
that satisfies the stated product contract and acceptance criteria.

The intended outcome is not a rewrite. The current Neovim workflow, detached
LSP, live-session bridge, ArkHelp, ArkView, and `{targets}` features already have
substantial regression coverage and should be preserved. The goal is to make
installation, upgrades, failure handling, maintenance, and performance as
deliberate as the feature set.

## Status

- TODO 1: complete — release foundation and product-owned CI (`b3ecb540`)
- TODO 2: complete — non-blocking and portable runtime boundary (`cffcef11`)
- TODO 3: complete — maintainable source and state boundaries (`68feabac`)
- TODO 4: complete — test pyramid and performance governance (`bfee7382`)
- TODO 5: complete — product polish, supportability, and documentation (`8d70e7ee`)

Update this section as each TODO is completed. If a TODO is deliberately
resolved through a different design, record the decision and link the commit or
ADR that replaced it.

## Recommended Ordering

1. Start TODO 1 first. It establishes the supported product, reproducible
   toolchain, artifact format, and required CI gates.
2. Start TODO 2 once the release contract is clear. It is the highest-risk
   runtime change and should not be mixed with broad file reorganization.
3. Start TODO 3 after TODO 2 has either landed or established stable interfaces.
   Mechanical extraction is much safer after the runtime boundary is known.
4. TODO 4 may begin alongside TODO 2, provided it adds characterization and
   contract coverage without refactoring the production path underneath TODO 2.
5. Finish TODO 5 before declaring a stable public release. Documentation and
   support tooling should describe the architecture that actually shipped.

TODOs may overlap when they touch disjoint files and have explicit owners. Do
not run large tmux-backed or full-config E2E suites concurrently; they can still
interfere through the managed-session contract even when individual harnesses
try to isolate state.

## Product Definition

For this roadmap, a dependable product has the following properties:

- installation on a supported platform does not require a Rust toolchain
- upgrades are versioned, checksummed, reversible, and tested
- static language features remain responsive when the R session or bridge is
  unavailable, slow, restarting, or incompatible
- supported Neovim, R, operating-system, and backend combinations are explicit
- the product's required CI checks exercise the Neovim product rather than only
  the inherited upstream Rust workspace
- common failures produce actionable status, logs, and recovery instructions
- performance claims are backed by repeatable budgets and recorded measurements
- maintainers can change one subsystem without understanding several thousand
  lines of unrelated UI, transport, and lifecycle code

The current v1 product boundary in `AGENTS.md` and `SPEC.md` remains authoritative.
Do not expand Positron, Jupyter, DAP, remote-session, or Windows managed-pane
scope while completing this roadmap.

## Ground Rules For Every TODO

- Inspect the live tree before editing. File sizes, dependencies, tests, and
  upstream divergence are observations from 2026-07-10, not permanent truths.
- Preserve static-only behavior. A runtime improvement is incomplete if it makes
  editing without a live R session worse.
- Preserve tmux as the canonical backend and the terminal backend as a narrower
  additive backend.
- Do not replace `vim-slime` or `nvim-slimetree` as the send layer.
- Prefer established Neovim, Rust, R-package, and release-engineering patterns
  over repo-specific machinery when they fit the product.
- Add characterization tests before changing an unclear contract.
- Keep refactors behavior-preserving unless a user-visible change is explicitly
  specified and documented.
- Avoid recovery branches that hide a broken invariant. Fix the state or
  ownership model that allowed the invalid condition.
- Keep commits scoped so a risky architectural step can be reviewed or reverted
  independently.
- Update `SPEC.md`, user documentation, and this file when a durable contract or
  decision changes.

Useful baseline commands:

```sh
git status --short --branch
git rev-list --left-right --count HEAD...upstream/main
cargo metadata --no-deps --format-version 1
cargo tree -p ark-lsp --depth 1 --edges normal
cargo +nightly fmt --all -- --check
cargo test -p ark-lsp-core --lib
./scripts/run-full-suite.sh --list-e2e
```

At the time of the review:

- the branch was 357 commits ahead and 0 behind `upstream/main`
- `cargo test -p ark-lsp-core --lib` passed 480 tests
- the canonical full-suite wrapper selected 219 serial Neovim E2Es
- the focused startup, completion, detached-LSP, and ArkView latency tests passed
- `just clippy` failed under Rust 1.97 because `rust-toolchain.toml` tracks moving
  `stable` while warnings are denied
- `R CMD check` for `arkbridge` completed with 2 warnings and 2 notes

These are discovery anchors, not acceptance criteria. Re-measure them.

## TODO 1: Establish a release foundation and product-owned CI

### Goal

Make `ark.nvim` installable, upgradeable, and testable as a versioned Neovim
product rather than as a source checkout that happens to build and run.

The normal supported installation should use an optimized `ark-lsp` artifact.
Compiling from source should remain available for contributors and unsupported
platforms, but should not be the default user experience.

### Why This Comes First

The current README asks users to install Rust and runs:

```sh
cargo build -p ark-lsp
```

That creates an unoptimized debug binary. `lua/ark/config.lua` also prefers
`target/debug/ark-lsp` before `target/release/ark-lsp` or a binary on `PATH`.
The review machine's debug executable was approximately 154 MB.

The checked-in GitHub workflows primarily build and test the inherited Ark Rust
workspace across macOS, Windows, and Linux. They do not run the repo-owned
Neovim/tmux E2Es, the README smoke path, `R CMD check` for `arkbridge`, or the
product's latency budgets. There is no product release workflow.

Relevant files:

- `README.md`
- `lua/ark/config.lua`
- `lua/ark/dev.lua`
- `Cargo.toml`
- `rust-toolchain.toml`
- `.github/workflows/check-rust.yml`
- `.github/workflows/test.yml`
- `.github/workflows/test-*.yml`
- `scripts/run-full-suite.sh`
- `scripts/docker-readme-test.sh`
- `CHANGELOG.md`

### Discovery Before Editing

Re-run:

```sh
rustc -Vv
cargo -V
git tag --sort=-creatordate | head -n 30
find .github/workflows -maxdepth 1 -type f -print | sort
rg -n 'cargo build|target/debug|target/release|ark-lsp' README.md lua scripts
rg -n '^version\s*=|^Version:' crates/*/Cargo.toml packages/*/DESCRIPTION
cargo metadata --no-deps --format-version 1
```

Also inspect current GitHub branch protection and recent workflow results if
credentials and network access are available. Do not infer remote required-check
state solely from the YAML files.

### Decisions To Make Before Implementation

Document the answers, preferably in a short ADR or a clearly marked section of
`SPEC.md`:

1. Which operating systems and architectures are release-tier for the first
   stable release?
2. Is Linux the only fully supported v1 platform, or is macOS also a release
   target? Do not imply Windows managed-pane support merely because inherited
   Rust crates compile on Windows.
3. What is the minimum glibc or macOS deployment target for prebuilt binaries?
4. Where is the single product version stored, and how is it propagated to the
   plugin, `ark-lsp`, `arkbridge`, protocol metadata, and release names?
5. Which protocol-version combinations are compatible across plugin, LSP, and
   bridge upgrades?
6. Should release binaries be installed into Ark-owned data storage, placed on
   `PATH`, or managed by an established Neovim package manager integration?
7. What is the rollback path after a failed or incompatible update?

Do not choose a distribution system only because it is easy to implement in
Lua. Prefer an established release-asset and checksum flow that can be tested in
a clean environment.

### Suggested Implementation Sequence

1. Define one release version and compatibility manifest.
2. Pin the release/development Rust toolchain to an exact version. Keep separate
   MSRV and nightly jobs if they are useful, but do not let a moving `stable`
   silently change the required gate.
3. Add Cargo `default-members` or product-specific commands so ordinary product
   builds do not compile inactive kernel/Jupyter/DAP crates unnecessarily.
4. Create `verify-product` and `verify-upstream-compat` commands. The former must
   be the required release gate; the latter may remain a broader scheduled or
   upstream-sync gate.
5. Add a product CI workflow covering formatting, product Rust tests, Lua/Neovim
   tests, `arkbridge`, a clean install, and a minimal live-session smoke.
6. Build optimized `ark-lsp` release assets on the supported builders. Record
   checksums and enough build metadata to reproduce an artifact.
7. Teach installation to select the correct asset, verify its checksum, install
   atomically, and preserve the previous working version until the new one
   passes a smoke check.
8. Change binary discovery so a packaged release is preferred. A repo-local
   debug binary should only win in an explicit development mode.
9. Retain a visible source-build fallback with a clear error when the toolchain
   is missing. Do not silently compile large Rust dependencies during normal
   buffer startup.
10. Replace the inherited changelog with product-facing release notes while
    retaining upstream attribution where relevant.

### Acceptable Implementation Routes

The exact installer may vary. Acceptable routes include:

- GitHub release assets installed into `stdpath("data") .. "/ark/bin"`
- a small Ark installer command that manages versioned directories and an
  atomic `current` pointer
- integration with an established Neovim binary manager, provided Ark still
  verifies compatibility and can report the installed version

A plugin-manager `build` hook may remain as a contributor fallback. It should
not be the only supported route and should build `--release` when intended for
normal use.

### CI Shape

Prefer a small required matrix and broader scheduled coverage:

- required PR checks: supported release platform, product Rust tests, Lua unit
  and contract tests, `R CMD check`, focused headless Neovim smoke
- required main/release check: build the real release artifact and install it
  into a clean README-minimal environment
- scheduled or pre-release: full serial tmux/TUI suite, R-version matrix,
  upstream compatibility, soak and performance jobs

Avoid privileged `pull_request_target` workflows unless they are essential and
cannot be implemented safely with ordinary `pull_request` plus minimal
permissions. Never execute untrusted PR code with write-capable credentials.

### Things To Watch

- `ark-lsp` dynamically interacts with the local R installation; prove artifact
  portability against the oldest supported system rather than assuming a binary
  built on the newest runner will work everywhere.
- Do not make release installation depend on the user's current working
  directory or plugin-manager layout.
- A partial download or interrupted upgrade must leave the previous binary
  usable.
- Plugin, LSP, and bridge versions may be updated at different moments. Reject
  incompatible combinations with an actionable message rather than a crash or
  silent fallback.
- Do not delete the source-build path used by contributors and upstream syncs.
- Keep release signing/checksum secrets out of pull-request jobs.

### Acceptance Criteria

- A clean supported machine can install and start Ark without Rust or Cargo.
- The installed `ark-lsp` is an optimized release artifact and Ark reports its
  product version and build metadata.
- The plugin never prefers an old debug binary over the installed release unless
  explicit development mode is enabled.
- A failed upgrade automatically leaves or restores a working previous version.
- Product CI runs on pull requests and exercises the actual Neovim product.
- The required gate is reproducible under an exact toolchain and is green.
- `arkbridge` is checked as part of product CI.
- The release process produces checksums and a clean-room install smoke result.
- User-facing release notes describe Ark changes rather than inherited Jupyter
  history.

### Verification

At minimum, add automated coverage for:

- selecting the correct artifact for each supported target
- checksum rejection
- interrupted installation and rollback
- incompatible component versions
- packaged binary discovery versus explicit development mode
- clean README-minimal installation with no pre-existing Rust target directory
- startup and a static LSP request using the installed artifact
- live bridge attach on the canonical supported platform

Record artifact size and cold/warm startup measurements, but do not set release
budgets from a single run. Use repeated samples and retain p50/p95 results as CI
artifacts.

### Stop And Re-plan If

- the release binary cannot be made portable across the proposed support floor
- version skew requires a protocol migration design not covered by the current
  `schema_version`
- the installer needs elevated privileges for the normal user path
- CI cannot exercise the same artifact users receive

## TODO 2: Make the live-runtime boundary non-blocking, bounded, and portable

### Goal

Ensure a slow, restarting, hung, or incompatible R bridge cannot stall unrelated
LSP requests or leave Neovim in an ambiguous readiness state.

The live R process is necessarily serialized, but `ark-lsp` should isolate that
serialization behind an asynchronous boundary. Static diagnostics, symbols,
navigation, and fallback completion should remain responsive when runtime work
is degraded.

### Current Discovery

`crates/ark-lsp-core/src/lsp/main_loop.rs` handles completion, hover, signature,
help, view, package, and target requests synchronously on one auxiliary event
loop. An existing `spawn_handler()` helper is marked unused.

`crates/ark-lsp-core/src/lsp/session_bridge.rs` performs blocking `TcpStream`
I/O. Dynamic requests may retry up to 30 times with sleep-based backoff. Normal
session requests default to a 1000 ms timeout, while ArkView commands can raise
the timeout to 10 seconds.

The pane-side `arkbridge` package runs a loopback TCP service in the interactive
R process. `packages/arkbridge/src/ipc.c` uses the public R input-handler API but
also assigns non-public `R_PolledEvents` and `R_wait_usec` globals. `R CMD check`
flags those calls as non-API usage.

Relevant files:

- `crates/ark-lsp-core/src/lsp/main_loop.rs`
- `crates/ark-lsp-core/src/lsp/handlers.rs`
- `crates/ark-lsp-core/src/lsp/session_bridge.rs`
- `crates/ark-lsp-core/src/lsp/state.rs`
- `crates/ark-lsp-core/src/lsp/state_handlers.rs`
- `lua/ark/lsp.lua`
- `lua/ark/session_runtime.lua`
- `packages/arkbridge/R/ipc_service.R`
- `packages/arkbridge/src/ipc.c`
- `scripts/ark-r-launcher.sh`
- `lessons/`

### Discovery Before Editing

Map every bridge-backed request and its current latency/fallback contract:

```sh
rg -n 'session_bridge\.|bridge_command|inspect\(' \
  crates/ark-lsp-core/src/lsp -g '*.rs'
rg -n 'request_sync|vim\.wait|session_timeout_ms|bridge_wait_ms' \
  lua/ark -g '*.lua'
rg -n 'R_PolledEvents|R_wait_usec|InputHandler|addInputHandler' \
  packages/arkbridge -g '*.{c,R}'
```

Classify requests into at least:

- latency-sensitive and read-only: completion, hover, signature help
- user-initiated and potentially slower: help, view, target inspection
- mutating: package installation and target actions
- lifecycle: ping, bootstrap, session refresh

Record current success, unavailable, stale-auth, stale-session, timeout, and
cancellation behavior for each class before choosing a concurrency design.

### Required Design Decisions

1. What immutable world/document snapshot does a concurrent handler need?
2. How will a response be rejected if the document version or session identity
   changed while the request was running?
3. Which requests may run concurrently, and which must be serialized through a
   bounded bridge queue?
4. What is the end-to-end deadline for each request class?
5. Which retry conditions indicate a connection refresh, and which should fail
   immediately?
6. How does cancellation propagate from Neovim/tower-lsp to pending bridge work?
7. When does repeated bridge failure open a circuit breaker, and what event
   closes it again?
8. Which fallback is valid for each request: static result, handled empty result,
   cached result, or explicit error?
9. Can the public R `InputHandler` path serve idle REPL requests reliably on all
   supported platforms without mutating `R_PolledEvents`?

Write these contracts down before replacing synchronous calls. Concurrency
without stale-result rules will create correctness bugs that are harder to
diagnose than the current latency problem.

### Suggested Implementation Sequence

1. Add deterministic tests for a slow bridge, hung bridge, connection refusal,
   auth-token rotation, session replacement, and cancellation.
2. Introduce a narrow bridge transport interface. Keep request planning and
   response interpretation outside the raw socket implementation.
3. Replace per-call implicit retries with an explicit retry/deadline policy.
   Bound total elapsed time, not only each socket attempt.
4. Move read-only bridge work off the auxiliary event loop using an appropriate
   Tokio task or blocking pool. Do not hold mutable world state across the task.
5. Add document/session generation checks before delivering results.
6. Add a bounded queue and backpressure for R-evaluating work. Completion bursts
   must not create an unbounded backlog in the interactive R session.
7. Add a circuit breaker or equivalent degraded-state model so repeated failures
   do not probe the same dead bridge on every keystroke.
8. Keep static request paths available while the bridge is open-circuit.
9. Evaluate removing the non-public R polling hook. Test the public input-handler
   route under idle REPL, active evaluation, browser/debug frames, raw tmux, and
   `nvim-console` conditions.
10. If non-public R integration remains necessary, isolate it behind a tiny
    version-specific adapter with explicit supported-R tests and a documented
    exit plan. Do not leave direct global mutation mixed into the core server.

### Acceptable Implementation Routes

For the Rust side, acceptable designs include:

- immutable request snapshots sent to `spawn_blocking` tasks
- a dedicated bridge worker with bounded channels and per-request deadlines
- asynchronous socket transport if it materially simplifies cancellation and
  deadlines without forcing the R side to become concurrent

Do not introduce concurrency merely to use async syntax. The important
properties are isolation, bounded work, cancellation, and freshness.

For the R side, acceptable outcomes include:

- public `InputHandler` integration only, if proven reliable
- a small public-API event-loop helper with platform-specific implementations
- a narrowly isolated compatibility layer for unsupported public-API gaps

A separate R daemon is not automatically suitable because runtime intelligence
must observe the real interactive session. Do not move evaluation out of that
session unless the design can preserve environment and browser-frame semantics.

### Things To Watch

- Returning zero completion items can still mean “handled.” Preserve the
  detached completion precedence contract.
- R evaluation is not thread-safe. Only the LSP waiting path should become
  concurrent; requests entering one R session must remain correctly serialized.
- Completion responses that arrive after the cursor or document changed should
  be dropped, not merged into newer results.
- Cancellation must not leave abandoned work queued inside the R session.
- Avoid retry storms during pane restart or bridge reinstall.
- ArkView and target actions legitimately take longer than completion. Use
  separate request classes rather than one global timeout.
- Preserve trusted status-file and auth-token validation.
- Preserve static-only operation with no tmux, terminal, or live session.

### Acceptance Criteria

- A deliberately hung bridge does not delay an unrelated static LSP request.
- Completion, hover, and signature help obey bounded end-to-end deadlines.
- Cancelled or stale requests do not deliver results into a newer document or
  session generation.
- Repeated bridge failure does not cause a connection attempt on every edit.
- A healthy bridge recovery event restores runtime features without restarting
  Neovim.
- The R-side service passes `R CMD check` without non-API compiled-code notes, or
  the remaining compatibility adapter has an explicit, justified, versioned
  support policy approved in the spec.
- Existing auth, readiness, restart, browser-frame, completion, ArkHelp,
  ArkView, and target workflows remain green.
- The main-loop slow-handler instrumentation no longer attributes bridge timeout
  time to the serialized event loop.

### Verification

Add or extend tests at three layers:

- Rust unit/contract tests with fake transports and controllable delays
- bridge integration tests using a fake or disposable TCP service
- serial Neovim/tmux E2Es proving visible fallback and recovery behavior

At minimum verify:

```sh
cargo test -p ark-lsp-core --lib
cargo +nightly fmt --all -- --check
just clippy
./scripts/run-e2e-test.sh --init NONE tests/e2e/detached_parity.lua
./scripts/run-e2e-test.sh --init NONE tests/e2e/current_env_completion_timing.lua
./scripts/run-e2e-test.sh --init NONE tests/e2e/bridge_auth_token_refresh.lua
./scripts/run-e2e-test.sh --init NONE tests/e2e/bridge_start_replaces_stale_client.lua
```

Run each E2E in its own `run-e2e-test.sh` invocation. The low-level runner
accepts one test script; additional positional arguments are passed to Neovim.

### Stop And Re-plan If

- the proposed concurrency model requires mutable `WorldState` on worker threads
- stale-response prevention cannot be expressed with a clear generation/version
  contract
- public R event integration cannot serve the idle REPL without unacceptable
  latency
- a fallback path would execute embedded-R-only code in detached mode

## TODO 3: Create maintainable source, state, and upstream boundaries

### Goal

Make the active product understandable as a set of small subsystems with explicit
ownership, while preserving behavior and keeping upstream language-analysis
work practical to import.

Success is not measured by file size alone. It is measured by whether a future
maintainer can change startup, tmux layout, ArkView rendering, console editing,
or bridge transport without loading several unrelated feature domains into
their head.

### Current Discovery

At the time of review, the largest active Lua files were:

- `lua/ark/init.lua`: 4,489 lines
- `lua/ark/console.lua`: 2,900 lines
- `lua/ark/view.lua`: 2,823 lines
- `lua/ark/tmux.lua`: 2,756 lines
- `lua/ark/lsp.lua`: 2,100 lines

`crates/ark-lsp-core/src/lsp/session_bridge.rs` was 6,766 lines and combined
transport, protocol types, request planning, R-expression construction, feature
clients, retry policy, and a large in-file test module.

State is distributed across module locals, `_G.__ark_nvim_state`,
`_G.__ark_nvim_console_state`, status files, LSP world state, bridge caches, and
several readiness concepts. `SPEC.md` already identifies startup/readiness
orchestration and duplicated completion semantics as hardening work.

The Cargo workspace still uses `members = ["crates/*"]`, so inherited kernel,
Jupyter, DAP, and test crates remain part of default workspace commands even
though `ark-lsp` itself is now a thin product binary.

### Discovery Before Editing

Recompute the map:

```sh
for file in lua/ark/*.lua; do
  printf '%6s %4s %s\n' \
    "$(wc -l < "$file")" \
    "$(rg -c '^(local )?function |^function M\.' "$file" || true)" \
    "$file"
done | sort -nr

rg -n '^local function |^function M\.' \
  lua/ark/init.lua lua/ark/console.lua lua/ark/view.lua \
  lua/ark/tmux.lua lua/ark/lsp.lua

rg -n '^pub|^fn |^    fn ' \
  crates/ark-lsp-core/src/lsp/session_bridge.rs

rg -n '_G\.__ark|startup_|runtime_ready|repl_ready|bridge_ready' \
  lua/ark tests/e2e -g '*.lua'
```

For each large file, write a responsibility inventory and identify which tests
protect each responsibility. Do not begin by moving functions based only on
their proximity or names.

### Target Boundaries To Evaluate

The following are candidate boundaries, not required filenames.

For `lua/ark/init.lua`:

- setup/composition root
- startup and readiness coordinator
- ArkHelp controller and rendering
- ArkView/open-routing controller
- package actions
- target actions and pickers

For `lua/ark/console.lua`:

- PTY/job lifecycle
- ANSI/output parser
- transcript model
- editable-input controller
- completion/signature integration
- console view/window configuration

For `lua/ark/view.lua`:

- ArkView state/model
- table layout and rendering
- paging/virtualization
- sticky-header rendering
- interactions, prompts, and keymaps
- profile/detail/pinned views

For `lua/ark/tmux.lua`:

- tmux command transport
- pane discovery and lifecycle
- layout policy
- tab parking/switching
- popup construction
- status publication

For `lua/ark/lsp.lua`:

- client configuration and lifecycle
- session synchronization
- request adapters
- status/cache handling
- development-binary integration

For `session_bridge.rs`:

- wire transport and retry/deadline policy
- request/response protocol types
- completion context planning
- R-expression construction
- help/package/view/target feature clients
- tests in dedicated modules or integration files

### Startup State Model

Before splitting startup code, define the canonical state transitions. At a
minimum distinguish:

- plugin configured
- detached LSP process starting
- LSP initialized but not hydrated
- static analysis ready
- managed session requested
- bridge runtime installing or current
- bridge ready
- REPL ready
- live session hydrated
- degraded static-only state
- stopping/restarting

Clarify which layer owns each transition and which signals are authoritative.
Do not infer `repl_ready` from `bridge_ready`, and do not synthesize readiness
across the Lua/Rust boundary when the owning layer can publish it directly.

A state machine may be represented with explicit data and transition functions;
it does not require a framework. The important requirement is that invalid
transitions are visible and testable.

### Suggested Implementation Sequence

1. Add characterization tests around public module APIs and high-risk state
   transitions.
2. Define narrow interfaces between controllers, transports, and renderers.
3. Extract pure functions first: formatting, parsing, layout calculation, and
   request construction.
4. Extract side-effectful controllers only after their dependencies can be
   injected or represented by narrow adapters.
5. Make `lua/ark/init.lua` a composition root that delegates feature behavior
   rather than continuing to own it.
6. Introduce the canonical startup state model and migrate one transition path
   at a time.
7. Split `session_bridge.rs` along the interface established in TODO 2. Do not
   reorganize its transport while another worker is changing transport behavior.
8. Set Cargo `default-members` to the active product crates and dependencies.
   Keep explicit commands for the retained upstream workspace.
9. Remove stale compatibility commands, inherited docs, or dead adapters only
   after usage and migration paths have been checked.
10. Update `SPEC.md` diagrams and ownership descriptions to match the result.

### Acceptable Implementation Routes

- several small behavior-preserving extraction PRs
- one subsystem at a time, each ending with a stable public facade
- temporary compatibility re-exports while callers migrate, provided they have
  a removal plan and do not become a second permanent API

Avoid a flag-day rewrite of all Lua modules. It would make regression diagnosis
and review unreasonably difficult.

### Things To Watch

- Module extraction can accidentally change require order, autocmd registration,
  global state restoration, and lazy-loading behavior.
- Do not duplicate mutable state between an old and new module during migration.
- Avoid generic “manager” or “utils” modules that become new dumping grounds.
- Keep tmux-specific capabilities first-class rather than forcing them through a
  least-common-denominator backend API.
- Do not move semantic completion decisions into more Lua modules; the canonical
  semantic planner belongs in Rust as described in `SPEC.md`.
- Preserve the active `ark-lsp-core` boundary during upstream syncs.
- File-count growth is acceptable when ownership becomes clearer; tiny files
  with circular imports are not an improvement.

### Acceptance Criteria

- Each major subsystem has a documented owner and narrow public interface.
- `lua/ark/init.lua` primarily composes modules and exposes the public plugin
  facade rather than implementing unrelated features.
- Startup/readiness transitions have one authoritative state model and tests for
  invalid or stale transitions.
- Bridge transport, protocol, and feature planning no longer live in one Rust
  module.
- Pure rendering/parsing/layout logic can be tested without starting tmux, R, or
  a full Neovim session where practical.
- Ordinary product Cargo commands do not build inactive kernel/Jupyter/DAP
  crates unless explicitly requested.
- No user-visible workflow regresses, and no temporary compatibility layer is
  left without a documented removal condition.
- `SPEC.md` and module READMEs describe the architecture that actually exists.

### Verification

Run focused tests after every extraction rather than waiting for the entire
reorganization:

```sh
cargo metadata --no-deps --format-version 1
cargo check -p ark-lsp-core -p ark-lsp
cargo test -p ark-lsp-core --lib
cargo +nightly fmt --all -- --check
just clippy
```

Use the appropriate Neovim tests for the subsystem being moved. At the end, run
the canonical product suite from TODO 4 and at least one clean README smoke.

### Stop And Re-plan If

- extraction requires circular imports or duplicated mutable state
- a proposed generic abstraction erases meaningful tmux versus terminal
  behavior
- source movement and behavior changes can no longer be reviewed separately
- upstream compatibility requires the active Neovim path to depend directly on
  Amalthea or frontend-specific types

## TODO 4: Build a fast test pyramid and performance-governance system

### Goal

Turn the existing large regression collection into a layered system that gives
fast pull-request confidence, deep pre-release confidence, and useful
performance evidence.

The current E2E investment is valuable and should not be discarded. The goal is
to move behavior to the cheapest valid layer and reserve full Neovim/tmux/TUI
tests for contracts that genuinely require them.

### Current Discovery

The canonical full-suite wrapper selected 219 Lua E2Es at review time and runs
them serially. Many tests correctly exercise real tmux, Blink, R, startup, and
bridge behavior, but pure layout, policy, formatting, state-transition, and R
payload behavior are also frequently tested through whole-process harnesses.

There is no checked-in Lua formatter/linter configuration, no clearly separated
Lua unit-test directory, and no `testthat` suite for `packages/arkbridge` despite
`testthat` being declared in `DESCRIPTION`.

Several useful performance probes exist, including startup, completion, bridge
RPC, and ArkView responsiveness checks. They are mostly pass/fail regressions,
not a versioned benchmark dashboard with repeated p50/p95 samples.

### Test Layers To Establish

Use names appropriate to the chosen harness, but preserve these conceptual
layers:

1. **Pure unit tests**
   - Rust parsing/planning/state functions
   - Lua formatting/layout/state functions under headless Neovim or a lightweight
     Lua harness
   - R payload, filtering, paging, help, target, and protocol functions under
     `testthat`
2. **Contract tests**
   - serialized plugin/LSP/bridge request and response shapes
   - protocol version compatibility
   - session identity and auth behavior
   - fake transport timeout/cancellation behavior
3. **Component tests**
   - headless Neovim with mocked tmux/LSP/bridge boundaries
   - `R CMD check` and compiled bridge loading
4. **Product E2Es**
   - real `ark-lsp`, R, bridge, tmux or terminal backend
   - Blink-visible completion and TUI behavior where presentation matters
5. **Clean-room and soak tests**
   - release artifact installation
   - repeated startup/restart/session churn
   - longer-running memory/process-leak and performance jobs

### Discovery Before Editing

Inventory and classify every E2E:

```sh
./scripts/run-full-suite.sh --list-e2e
find tests/e2e -maxdepth 1 -type f -name '*.lua' -printf '%f\n' | sort
rg -l 'tmux|TMUX' tests/e2e/*.lua
rg -l 'blink.cmp is required' tests/e2e/*.lua
rg -n 'vim\.wait|request_sync|vim\.fn\.system' tests/e2e lua/ark -g '*.lua'
find packages/arkbridge -maxdepth 3 -type f | sort
```

For each test record:

- contract protected
- required dependencies
- typical runtime and flake history
- whether it mutates shared session state
- cheapest layer that can prove the same behavior
- whether a higher-level smoke should remain after lower-level coverage is added

Do not delete an E2E merely because a unit test is easier. Retain a small
end-to-end proof for each critical user journey.

### Suggested Implementation Sequence

1. Add a machine-readable test manifest or metadata convention describing tier,
   dependencies, serial requirements, and ownership.
2. Add `testthat` coverage for `arkbridge` before changing its IPC or view logic.
3. Add a maintained Lua unit/component harness. Prefer a well-supported Neovim
   testing pattern over more bespoke shell behavior, but avoid making runtime
   users install test-only plugins.
4. Move pure policy/layout/parser assertions down from E2E tests where that
   materially improves speed and failure clarity.
5. Keep focused request-level and real-config/TUI tests for completion bugs that
   can differ between explicit LSP requests and visible Blink behavior.
6. Split the product suite into fast required, serial integration, full TUI, and
   scheduled soak groups.
7. Make the full-suite wrapper consume the same manifest as CI so lists cannot
   silently drift.
8. Add repeated benchmark collection for startup, completion, RPC latency,
   ArkView page/open/cursor paths, process count, and memory where useful.
9. Upload structured results and logs from CI. Compare against a rolling baseline
   with tolerance for environmental noise rather than one absolute sample.
10. Track flakes explicitly. A retry may collect evidence, but should not turn a
    reproducible semantic failure into a pass.

### Performance Governance

For each benchmark define:

- user-visible event being measured
- cold versus warm conditions
- fixture size and machine/environment assumptions
- number of samples
- p50 and p95, plus worst-case where meaningful
- regression threshold and noise allowance
- artifact format and baseline update process

Retain the current 350 ms startup regression as a focused guard, but establish
whether it measures buffer unlock, LSP initialization, bridge readiness, or full
live completion before presenting it as a general startup claim.

Do not optimize aggregate test runtime by parallelizing tmux-backed full-config
tests that share or compete for the same managed session. Prefer lower-layer
tests, sharding of isolated tests, or dedicated runners.

### R Package Quality Gate

Bring `packages/arkbridge` to at least:

- `R CMD check --no-manual` with zero warnings
- justified and tracked notes only, with the goal of zero notes for supported
  public APIs
- declared optional dependencies
- documentation or explicit internal status for exported functions
- unit tests for IPC dispatch, schema/error payloads, view filtering/paging,
  help rendering, target actions, and package behavior
- compiled-code tests across supported R versions and platforms

Tests that mutate `utils` bindings or install hooks must restore the prior state
even after failure.

### Things To Watch

- `scripts/run-e2e-test.sh` accepts one test script. Passing several scripts to
  one invocation does not run a suite.
- One-off bridge startup timeouts can be environmental; retry once to classify
  them, then investigate if reproducible.
- A `-u NONE` pass proves Ark isolation, not full user-config behavior.
- A full-config test must use a prepared plugin cache or reproducible fixture.
  It should not unexpectedly clone the user's entire plugin graph during the
  assertion phase.
- Avoid tests that mock so much state that they no longer represent the real
  contract.
- Keep secrets and auth tokens out of uploaded logs and snapshots.

### Acceptance Criteria

- Pull requests receive a fast, deterministic product-confidence result.
- Every critical journey retains at least one product-level E2E.
- Pure Lua and R behavior no longer requires tmux or a full live session to test.
- `arkbridge` has a real `testthat` suite and a clean required package check.
- Test tiers and serial requirements are declared in one source of truth.
- Performance jobs record repeatable p50/p95 results and retain artifacts.
- Regressions name the affected contract rather than only reporting a generic
  startup timeout.
- Full-config coverage uses a reproducible prepared environment.
- The canonical full suite remains available for pre-release confidence even if
  it is no longer required on every pull request.

### Verification

The implementation should prove the harness itself:

- temporarily break one test in each tier and confirm CI fails in the expected
  job
- confirm serial tests never overlap
- confirm failed E2Es retain useful artifacts and successful E2Es clean up
- confirm performance result parsing rejects missing or malformed samples
- confirm the release artifact, not a stale repo binary, is used by clean-room
  jobs
- compare the new suite's protected user journeys with the pre-migration test
  inventory before deleting or moving old tests

### Stop And Re-plan If

- the new harness requires production users to install test dependencies
- moving tests down a layer removes the only proof of visible editor behavior
- benchmark noise is larger than the proposed regression threshold
- CI speed improvements depend mainly on hiding failures through retries

## TODO 5: Finish product polish, diagnostics, and user documentation

### Goal

Make Ark understandable and supportable by someone who did not build it, with
consistent UX, actionable failures, native documentation, and a safe way to
collect a redacted diagnostic report.

This TODO should describe the product shipped by TODOs 1–4. Do not document a
planned architecture as though it already exists.

### Current Discovery

The repository has a useful `:checkhealth ark`, extensive notifications,
launcher logs, status files, LSP tracing, and many targeted diagnostics. These
facilities are fragmented across layers and do not yet form one support story.

There is no native `doc/ark.txt` help file. Much of `doc/` is inherited
Positron/Jupyter material. `CHANGELOG.md` is inherited and does not represent the
Ark.nvim product. Component versions are not unified, and configuration accepts
deeply merged tables without a complete user-facing validation or migration
contract.

Relevant files:

- `README.md`
- `doc/`
- `CHANGELOG.md`
- `lua/ark/config.lua`
- `lua/ark/health.lua`
- `lua/ark/init.lua`
- `lua/ark/lsp.lua`
- `lua/ark/bridge.lua`
- `scripts/ark-r-launcher.sh`
- `packages/arkbridge/R/schema.R`

### Product UX Contracts To Define

Define a small set of user-visible runtime states and use them consistently:

- ready with static and live features
- static ready while R is starting
- static-only by configuration or unavailable backend
- live features degraded because the bridge is unavailable or incompatible
- update/install in progress
- restart required
- unsupported configuration or platform

For each state define:

- what still works
- what Ark displays automatically
- what appears only in `:Ark status` or health output
- whether user action is required
- the exact recovery action

Avoid repeated warning notifications for the same persistent state. A single
actionable transition message plus durable status is preferable to warning spam.

### Suggested Implementation Sequence

1. Inventory public commands, configuration keys, environment variables, error
   messages, logs, and status fields.
2. Define a stable error taxonomy shared across plugin, LSP, and bridge layers.
   Preserve machine-readable codes and map them to concise user actions.
3. Add structured request/session identifiers across Lua, Rust, launcher, and R
   logs so one operation can be followed end to end.
4. Add a redacted support command such as `:Ark report` that collects component
   versions, supported-environment facts, current state, recent relevant logs,
   and health results without exposing auth tokens, arbitrary environment
   variables, source code, or sensitive paths unnecessarily.
5. Expand `:checkhealth ark` to verify the released installation contract,
   component compatibility, writable state locations, supported R/Neovim
   versions, backend requirements, and recovery commands.
6. Add configuration validation with precise paths and accepted values. Provide
   deprecation warnings and migrations for renamed keys.
7. Write `doc/ark.txt` with setup, commands, configuration, status model,
   backends, troubleshooting, development mode, and links to deeper docs.
8. Rewrite the README around installation and first success. Move contributor
   and architecture detail into dedicated docs.
9. Replace or archive inherited Positron/Jupyter documentation that does not
   describe the supported product.
10. Establish product-facing release notes, upgrade notes, and a compatibility
    table.

### Diagnostic Report Safety

The support report must redact or omit:

- auth tokens and session cookies
- arbitrary environment-variable values
- source buffer contents and R object values
- exact sensitive network identifiers
- unrelated logs from the user's system

Prefer reporting retrieval locations and normalized component facts over dumping
whole files. Include a preview/confirmation step before copying or writing a
report if it may contain user-specific paths.

Telemetry is not required by this TODO. Do not add remote data collection without
a separate explicit product decision and consent model.

### Documentation Structure To Consider

- `README.md`: product promise, requirements, install, minimal setup, first-run
  verification, links
- `doc/ark.txt`: complete native Neovim reference
- `docs/troubleshooting.md` or equivalent: symptoms, status states, recovery
- `docs/architecture.md`: plugin/LSP/bridge boundaries and upstream relationship
- `CHANGELOG.md`: Ark.nvim releases only
- `SPEC.md`: current contract and near-term design direction
- TODO documents: planned work, not claims about current behavior

Use the repository's preferred location and naming conventions if they evolve
before implementation.

### Things To Watch

- Keep documentation consistent with the actual default configuration. The
  review found `async_startup = false` in defaults while the recommended README
  setup enabled it explicitly.
- Do not tell users to run developer-only build or cache-clearing commands as the
  first response to ordinary failures.
- Health checks should be read-only and should not start an R session.
- Support reports must work in degraded/static-only mode.
- Avoid exposing every internal compatibility command as primary UX. Keep
  `:Ark` as the coherent discovery surface and document compatibility commands
  separately.
- Accessibility includes readable highlights, keyboard-only operation, stable
  focus behavior, and errors that do not rely on color alone.

### Acceptance Criteria

- A new user can install, configure, verify, and use the first R workflow from
  product documentation without reading contributor notes.
- `:help ark` provides a complete command and configuration reference.
- `:checkhealth ark` identifies incompatible components and gives concrete
  recovery steps without starting a session.
- A redacted diagnostic report can be generated in healthy and degraded states.
- Persistent failures produce one coherent state and recovery path rather than
  repeated unrelated warnings.
- Configuration errors name the exact invalid key/value and supported choices.
- Plugin, LSP, bridge, and protocol versions are visible and compatible with the
  release manifest from TODO 1.
- Inherited docs that describe unsupported Positron/Jupyter surfaces are removed,
  archived, or clearly separated from product documentation.
- Upgrade and rollback instructions are tested against real release artifacts.

### Verification

- Run help-tag generation and a headless `:help ark` lookup.
- Test health output with missing tmux, missing R, missing `jsonlite`, stale
  bridge, incompatible versions, read-only state directories, and terminal
  backend configuration.
- Snapshot or structurally test configuration errors and error-code-to-action
  mappings.
- Generate a support report from fixtures containing fake secrets and prove they
  are redacted.
- Follow the README from a clean environment using the release artifact.
- Conduct a manual keyboard/focus/readability pass for ArkHelp, ArkView,
  `nvim-console`, build logs, and error flows.

### Stop And Re-plan If

- documentation requires users to understand internal readiness signals to
  recover from normal failures
- the support report cannot guarantee secret redaction
- configuration validation would reject currently supported dynamic extension
  points without a migration design
- user-facing state names do not map cleanly to the authoritative state model
  created in TODO 3

## Completion Definition For The Roadmap

This roadmap is complete when all five TODOs are implemented or deliberately
resolved, the status section records the outcome, and a release candidate proves:

1. clean install without Rust on every supported release platform
2. reproducible, checksummed, rollback-safe artifacts
3. responsive static LSP behavior while the bridge is unavailable or hung
4. clean required Rust, Lua/Neovim, and R-package gates
5. repeatable startup and interaction performance within documented budgets
6. successful canonical tmux workflow and terminal-backend smoke
7. actionable health, logs, and redacted support output
8. documentation and version metadata matching the shipped components

Only after those conditions are met should the project treat broad feature
expansion as higher priority than product hardening.
