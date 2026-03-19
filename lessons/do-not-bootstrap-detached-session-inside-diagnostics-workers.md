# Do Not Bootstrap Detached Session Inside Diagnostics Workers

## Context

Detached Ark diagnostics are computed in background workers from a cloned `WorldState` snapshot, while live completions run against the authoritative current session path.

## What Went Wrong

The diagnostics worker was still calling detached session bootstrap on its cloned state before generating diagnostics.

That created a split:

- completions used the real live bridge/session state
- diagnostics mutated a throwaway clone and then discarded it

So diagnostics could stay stale, lag behind, or repeatedly re-bootstrap even when live completions were already correct.

## Invariant

- detached session bootstrap must happen only on the authoritative main-state path
- background diagnostics workers must read the latest stored `WorldState` snapshot but must not try to hydrate live session inputs themselves
- after detached session state is refreshed on the main path, that refreshed state must be stored and then diagnostics can be queued from it

## Practical Rule

If a diagnostics task seems to need to “just refresh” detached live state for itself, do not add that logic there. Move the refresh to the main-state/session-update path and let diagnostics consume the resulting snapshot.
