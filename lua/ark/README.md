# Ark Lua module ownership

`lua/ark/init.lua` is the composition root and public plugin facade. It wires
the modules below together and retains only cross-feature coordination and the
stable `require("ark")` API.

Active subsystem owners:

- `startup_state.lua`: authoritative per-buffer startup generations, LSP and
  managed-session phases, readiness reconciliation, invalid/stale transition
  reporting, and startup timing traces. Its pure `transition()` function is the
  state-machine contract.
- `help_render.lua`: ArkHelp text parsing, table-of-contents construction,
  reference layout, highlights, and the in-process read-only float. It does not
  start R, tmux, or an LSP.
- `target_actions.lua`: package-install and `{targets}` project/action/view
  controller. Dependencies on readiness, LSP requests, ArkView, and the public
  facade are injected by `init.lua`.
- `lsp.lua`: Neovim LSP client lifecycle, session synchronization, Ark request
  adapters, and client-side status caching.
- `session.lua`: the narrow backend contract and backend selection.
- `tmux.lua` and `terminal.lua`: backend-specific lifecycle and UX. Tmux layout,
  tabs, parking, and popup capabilities remain tmux-owned.
- `console.lua`: built-in console PTY, transcript, input, and console UI.
- `view.lua`, `object_view.lua`, and `target_view.lua`: ArkView models and UI.
- `bridge.lua` and `session_runtime.lua`: pane-side runtime installation and
  trusted status/runtime metadata.
- `release.lua`, `dev.lua`, and `health.lua`: packaged artifacts, contributor
  builds, and support diagnostics respectively.

Readiness ownership is deliberately split by evidence source: the backend owns
`bridge_ready` and `repl_ready`; `ark-lsp` owns static and live hydration; and
`startup_state.lua` reconciles those published signals without inventing one
from another. New feature modules should expose a small domain API and receive
side-effectful collaborators explicitly rather than importing `ark.init`.
