# Do Not Synthesize `repl_ready` Across The Lua/Rust Boundary

## Context

`ark.nvim` has two different consumers of startup state:

- the Neovim Lua layer, which can infer prompt readiness by inspecting the tmux pane
- the detached Rust LSP bridge, which discovers live bridge connectivity from the trusted startup status file

## Lesson

Do not send `ark/updateSession` with `replReady = true` just because Lua can see a stable `>` prompt if the status file still says `repl_ready = false`.

That creates a readiness split:

- Lua believes the managed R session is ready
- Rust still refuses bootstrap because the status file is not yet prompt-ready
- the session watcher can stop early because it thinks readiness has already been reached
- diagnostics can get stuck on static state like `No symbol named 'library' in scope.` and `No symbol named 'browser' in scope.`

## Correct invariant

For detached LSP session updates, `replReady` must mean something the Rust bridge can trust immediately.

Today that means:

- prefer the authoritative status-file `repl_ready` bit for LSP session payloads
- keep prompt-derived readiness as a Lua/UI concern unless the update payload also carries a live connection form that bypasses status-file revalidation

## Practical debugging signal

If runtime completions work eventually but diagnostics complain about base symbols like `library()` or `browser()` on startup, suspect a split between:

- Lua session readiness
- status-file readiness used by detached Rust bootstrap
