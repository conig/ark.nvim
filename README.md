ark.nvim
========

`ark.nvim` is a Neovim-only refactor of Ark for R development with:

- a native Rust LSP server
- a Neovim plugin
- a managed tmux pane running interactive `R`
- `nvim-slimetree` + `vim-slime` as the execution path

## Direction

The intended workflow is:

1. Open an `r`, `rmd`, `qmd`, or `quarto` buffer.
2. `ark.nvim` starts or reuses one tmux pane running `R`.
3. You keep sending code with `nvim-slimetree` / `vim-slime`.
4. Neovim language features come from `ark-lsp`.

This repository still contains large parts of upstream Ark while the refactor is in progress, but the product scope is now Neovim-only. See [AGENTS.md](AGENTS.md) and [SPEC.md](SPEC.md) for the project contract.

## Current Repo Surface

Today the repo contains:

- `crates/ark/src/bin/ark-lsp.rs`
  - a standalone stdio LSP entrypoint for Neovim
- `lua/ark/` and `plugin/ark.lua`
  - the Neovim plugin and managed-pane integration
- `scripts/ark-r-launcher.sh`
  - the managed-pane launcher and live-session bootstrap
- `packages/rscope`
  - a vendored local R runtime package used for session IPC inside the managed pane

The upstream kernel, DAP, and Positron/Jupyter code are still present as migration material.

## Minimal Neovim Setup

```lua
require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
})
```

Useful commands:

- `:ArkPaneStart`
- `:ArkPaneRestart`
- `:ArkPaneStop`
- `:ArkLspStart`
- `:ArkRefresh`
- `:ArkStatus`
- `:ArkPaneCommand`

To integrate with `vim-slime`, leave `configure_slime = true` in setup.

## LSP

The repo now provides `ark-lsp`, a stdio LSP binary intended for Neovim.

Current default launch args:

```sh
ark-lsp --runtime-mode detached
```

`detached` mode is the safe default for Neovim because the editor-facing LSP runs out of process from the managed tmux R session.
`ark-lsp` now also accepts managed-session bridge metadata through environment variables so detached mode can query the tmux R session for completions, hover, and signature help.

## Managed tmux Pane

The plugin launches the managed R pane through the repo-local launcher:

```sh
scripts/ark-r-launcher.sh
```

That launcher bootstraps the vendored `packages/rscope` runtime into a writable user library under Neovim's data directory and writes trusted readiness metadata to `stdpath("state") .. "/ark-status"`.

Environment knobs:

- `ARK_NVIM_R_BIN`
- `ARK_NVIM_R_ARGS`
- `ARK_NVIM_LSP_BIN`
- `ARK_NVIM_SESSION_LIB`
- `ARK_NVIM_SESSION_PKG_PATH`

Pane width respects the first available tmux/global setting from:

- `TMUX_CODING_PANE_WIDTH`
- `TMUX_JOIN_WIDTH`
- `GOOTABS_JOIN_WIDTH`

## Building

See [BUILDING.md](BUILDING.md).

## Status

The current implementation gives the repo:

- a documented Neovim-only scope
- a standalone LSP entrypoint
- a real plugin surface for pane management and LSP startup
- a detached live-session bridge for completions, hover, and signature help against the managed tmux R pane

Remaining work is now in depth and polish rather than basic architecture extraction: expanding test coverage and tightening Neovim-facing docs and health tooling.

## License

The repository remains under the MIT license inherited from upstream Ark.
