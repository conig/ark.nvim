# Non-Interactive Child `R` Processes Must Not Overwrite Pane Status

## Context

The launcher injects a temporary `R_PROFILE_USER` so the interactive tmux pane can install `rscope`, start the IPC bridge, and publish trusted pane status.

But child `R` processes spawned from inside that pane, such as `crew` workers or `system2("R", ...)`, inherit that profile path by default.

## Lesson

Only the interactive pane-owned REPL may publish Ark pane status.

If a non-interactive child `R` process runs the launcher profile, it can overwrite the pane status file with:

- the child PID
- a different bridge port/auth token
- `repl_ready = false`

That leaves detached Ark pointed at the wrong runtime and produces mass static diagnostics like:

- `No symbol named 'library' in scope.`
- other base/session symbols reported as missing

## Correct invariant

After sourcing the user's real profile, the launcher bootstrap must no-op when `interactive()` is false.

That keeps:

- child workers free to inherit normal R startup behavior
- pane status ownership with the interactive tmux REPL
- detached LSP session discovery attached to the correct pane runtime

## Practical debugging signal

If a managed pane is busy running a long job and Ark suddenly shows base symbols as missing, inspect the pane status file:

- if the status `pid` belongs to a worker `R -e ...` process instead of the pane REPL
- and `repl_ready` has fallen back to `false`

then a child R process has stolen pane status ownership.
