# Rebuild the detached `ark-lsp` binary before trusting live E2E results

## Context

Detached Neovim runs do not exercise Rust changes directly from library tests.
The live tmux-backed path launches `target/debug/ark-lsp`.

## Lesson

After changing Rust code that affects detached LSP behavior, rebuild the actual binary before evaluating headless Neovim or tmux-backed end-to-end behavior.

Use:

```sh
cargo build -p ark --bin ark-lsp
```

The Neovim plugin should also make this easier in repo-dev mode:

- prefer the repo-built `target/debug/ark-lsp` when it exists
- expose an explicit rebuild helper like `:ArkBuildLsp`
- refuse silent source/binary drift when launching the detached LSP from the repo checkout

Do not assume `cargo test` alone refreshed the executable that Neovim will spawn.

## Why this matters

It is easy to get a false architectural signal from stale binaries:

- library tests can pass on new code
- live E2E can still be running old detached-server behavior
- that mismatch can look like a bridge lifecycle or diagnostics design failure when the real issue is build state

When unit results and live detached behavior disagree, check for a stale `target/debug/ark-lsp` first.
