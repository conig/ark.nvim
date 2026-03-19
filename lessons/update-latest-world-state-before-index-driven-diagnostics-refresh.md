# Update The Latest `WorldState` Before Index-Driven Diagnostics Refresh

## Context

Ark's background diagnostics worker does not read the `WorldState` passed into `index_update()`.
It reads the globally cached latest snapshot.

## Lesson

If a document edit queues index work and then asks for a diagnostics refresh, update the shared latest-world snapshot first.

In practice:

- `index_create()`
- `index_update()`
- `index_delete()`
- `index_rename()`

must all refresh the cached latest `WorldState` before they queue diagnostics work.

## Why this matters

Without that update, diagnostics can split from the visible buffer:

- the user edits the document
- index tasks run for the new document contents
- background diagnostics still read an older cached document snapshot
- Neovim can end up clearing diagnostics or keeping stale ones instead of publishing the new syntax error

This is easiest to reproduce when:

- static diagnostics appear before the live session is ready
- live attach later clears those static diagnostics
- the next real edit introduces a syntax error that should now be shown immediately

If the editor shows diagnostics disappearing after a real edit in a live-attached buffer, suspect a stale latest-`WorldState` cache before blaming the parser or tmux bridge.
