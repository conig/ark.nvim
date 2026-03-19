# Do Not Probe Detached Bridge On Every Edit

## Context

Detached `ark-lsp` can hydrate live session inputs from the tmux-managed R bridge, but those bridge calls are synchronous and may retry internally on transient I/O failures.

## What Went Wrong

`didOpen()` and `didChange()` both called detached session bootstrap opportunistically whenever console scopes, installed packages, or library paths were still empty.

That meant:

- opening a buffer could probe the bridge before the authoritative `repl_ready` state had fully propagated
- every later edit could probe the bridge again if bootstrap had not succeeded yet
- when the bridge or R session was slow, busy, or not fully ready, normal editing churned through repeated bridge retry loops

This manifested as startup confusion, late completions, cursor fluttering, and delayed cleanup of static diagnostics.

## Invariant

- detached non-forced bootstrap may probe the bridge at most once per session state
- `didChange()` must not trigger detached live bootstrap probing
- a new authoritative `ark/updateSession` notification resets the one-shot guard and is the canonical moment for another bootstrap attempt

## Practical Rule

If detached live hydration seems tempting from an edit-path callback, do not add it there. Keep edit paths local and cheap; let session updates re-arm live bootstrap instead.
