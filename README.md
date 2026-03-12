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
  - the Neovim plugin skeleton
- `scripts/ark-r-launcher.sh`
  - the default managed-pane launcher

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
- `:ArkStatus`
- `:ArkPaneCommand`

To integrate with `vim-slime`, leave `configure_slime = true` in setup.

## LSP

The repo now provides `ark-lsp`, a stdio LSP binary intended for Neovim.

Current default launch args:

```sh
ark-lsp --runtime-mode detached
```

`detached` mode is the safe default for Neovim while the live-session bridge is being extracted from upstream Ark's kernel-coupled runtime.

## Managed tmux Pane

The default launcher is:

```sh
scripts/ark-r-launcher.sh
```

Environment knobs:

- `ARK_NVIM_R_BIN`
- `ARK_NVIM_R_ARGS`
- `ARK_NVIM_LSP_BIN`

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

The remaining major milestone is the live-session bridge that lets `ark-lsp` query the tmux-managed R process for runtime-aware completions, hover, and signatures.

## License

The repository remains under the MIT license inherited from upstream Ark.
