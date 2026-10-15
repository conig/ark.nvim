# Ark Lua module ownership

`lua/ark/init.lua` is the composition root and public plugin facade. It wires the modules below together and retains only cross-feature coordination and the stable `require("ark")` API.

Active subsystem owners:

- `startup_state.lua`: authoritative per-buffer startup generations, LSP and managed-session phases, readiness reconciliation, invalid/stale transition reporting, and startup timing traces. Its pure `transition()` function is the state-machine contract.
- `help_render.lua`: ArkHelp text parsing, table-of-contents construction, reference layout, highlights, and the in-process read-only float. It does not start R, tmux, or an LSP.
- `target_actions.lua`: package-install and `{targets}` project/action/view controller. Dependencies on readiness, LSP requests, ArkView, and the public facade are injected by `init.lua`.
- `targets_preview.lua`: explicit asynchronous on-disk rebuild previews, bounded disposable-worker output, cancellation, and unsaved-buffer warnings. `scripts/ark-targets-preview.R` owns the public `tar_outdated()`/`tar_network()` calls; previews never build targets or run in the managed R session.
- `traceback.lua`: explicit last-uncaught-error/saved-target traceback picker and genuine-source-reference navigation. Live data comes through `ark/internal/errorTraceback`; saved target data comes from `scripts/ark-target-traceback.R`. It does not install error hooks, evaluate frames, or add call text to support reports.
- `lsp.lua`: Neovim LSP client lifecycle, session synchronization, and client-side status caching; `lsp_request_adapter.lua` owns custom-request adaptation and asynchronous cancellation/deadlines. Frontmatter schemas and file-reference diagnostics belong to `crates/ark-lsp-core/src/lsp/frontmatter/semantic.rs`, not a parallel Lua completion source.
- `session.lua`: the narrow backend contract and backend selection.
- `tmux.lua` and `terminal.lua`: backend-specific lifecycle and UX. Tmux layout, tabs, parking, and popup capabilities remain tmux-owned.
- `console.lua`: built-in console PTY, transcript, input, console UI, and submission-to-prompt busy evidence.
- `view.lua`, `object_view.lua`, and `target_view.lua`: ArkView models and UI; `value_picker.lua` owns bounded asynchronous filtering interactions, while the R bridge owns data computation.
- `bridge.lua` and `session_runtime.lua`: pane-side runtime installation and trusted status/runtime metadata.
- `product_state.lua` and `report.lua`: evidence-based product/activity classification and redacted, bounded support summaries. Busy, unknown unresponsiveness, and disconnection are distinct; elapsed bridge time is not proof that R crashed.
- `release.lua`, `dev.lua`, and `health.lua`: packaged artifacts, contributor builds, and environment/installation health respectively.

Readiness ownership is deliberately split by evidence source: the backend owns `bridge_ready` and `repl_ready`; `ark-lsp` owns static and live hydration; and `startup_state.lua` reconciles those published signals without inventing one from another. New feature modules should expose a small domain API and receive side-effectful collaborators explicitly rather than importing `ark.init`.
