ark.nvim
========

`ark.nvim` is a Neovim-first R tooling stack built around three pieces:

- `ark-lsp`, a native Rust language server for R
- a Neovim plugin that starts or reuses one managed tmux pane running interactive `R`
- `nvim-slimetree` plus `vim-slime` for code sending into that REPL

This repo started as upstream Ark, so it still contains kernel, Positron, and other migration-era code. That is not the product surface anymore. The active scope is a local, Neovim-only workflow where:

- Neovim talks to `ark-lsp` over stdio
- the live R session stays in tmux
- runtime-aware features cross the tmux boundary through the managed session bridge
- REPL execution stays with `nvim-slimetree` and `vim-slime`

## Scope

`ark.nvim` is for:

- Neovim R development
- one managed tmux R pane per Neovim instance
- standard LSP features such as diagnostics, hover, definitions, references, symbols, and code actions
- live-session completions, hover, and signatures when the managed R session is available

`ark.nvim` is not for:

- Positron
- Jupyter kernels
- notebook execution
- DAP
- replacing `vim-slime` or `nvim-slimetree`
- remote or multi-host tmux workflows

## Architecture

The intended workflow is:

1. Open an `r`, `rmd`, `qmd`, or `quarto` buffer in Neovim.
2. `ark.nvim` creates or reuses one managed tmux pane running `R`.
3. `nvim-slimetree` and `vim-slime` send code to that pane.
4. `ark-lsp` provides static language features through Neovim's built-in LSP client.
5. When the managed R session is ready, `ark-lsp` augments static analysis with live-session intelligence through the bridge runtime.

The important boundary is that the REPL does not live inside the LSP process. `ark.nvim` manages the tmux session, the launcher bootstraps the bridge runtime, and the LSP consumes that session metadata when it starts in detached mode.

## Prerequisites

You need:

- Neovim with built-in LSP support
- `tmux`, and Neovim must itself be running inside tmux
- `R >= 4.2`
- the R package `jsonlite`
- a Rust toolchain capable of building the workspace (`rust-version = 1.94`)

The repo defaults to the `stable` Rust channel. If your installed `stable`
toolchain is older than `1.94`, update it first:

```sh
rustup update stable
```

Install the R dependency once:

```r
install.packages("jsonlite")
```

## Installation

The simplest `lazy.nvim` setup is to let the plugin build `ark-lsp` inside its own checkout, then let `ark.nvim` find `target/debug/ark-lsp` automatically.

If you already run another R LSP such as `r_language_server`, disable it for `r`, `rmd`, `qmd`, and `quarto` first. `ark.nvim` is meant to be the only R LSP client for those buffers.

```lua
return {
  {
    "jpalardy/vim-slime",
    ft = { "r", "rmd", "qmd", "quarto" },
    init = function()
      vim.g.slime_no_mappings = 1
      vim.g.slime_dont_ask_default = 1
      vim.g.slime_bracketed_paste = 0
    end,
  },
  {
    "conig/nvim-slimetree",
    ft = { "r", "rmd", "qmd", "quarto" },
    dependencies = { "jpalardy/vim-slime" },
    config = function()
      require("nvim-slimetree").setup({
        gootabs = {
          enabled = false,
        },
      })

      local st = require("nvim-slimetree")
      local map = vim.keymap.set

      map("n", "<CR>", function()
        st.slimetree.send_current()
      end, { desc = "Send current R form" })

      map("n", "<leader><CR>", function()
        st.slimetree.send_current({ hold_position = true })
      end, { desc = "Send current R form and hold cursor" })

      map("n", "<C-c><C-c>", function()
        st.slimetree.send_line()
      end, { desc = "Send current R line" })

      map("x", "<CR>", "<Plug>SlimeRegionSend", { remap = true, silent = true })
    end,
  },
  {
    "conig/ark.nvim",
    ft = { "r", "rmd", "qmd", "quarto" },
    dependencies = {
      "jpalardy/vim-slime",
      "conig/nvim-slimetree",
    },
    build = "cargo build -p ark --bin ark-lsp",
    config = function()
      require("ark").setup({
        auto_start_pane = true,
        auto_start_lsp = true,
        async_startup = true,
        configure_slime = true,
      })
    end,
  },
}
```

### Local checkout

If you are developing from a local clone instead of GitHub, use `dir = "~/repos/ark.nvim"` in the `lazy.nvim` spec. The same build command works and `ark.nvim` will still auto-detect the freshly built `target/debug/ark-lsp`.

## REPL Workflow

`ark.nvim` does not replace your send-code workflow. It manages the pane and points `vim-slime` at the correct tmux target.

With `configure_slime = true`:

- `ark.nvim` starts or reuses the tmux pane
- `ark.nvim` updates `vim.g.slime_target` and `vim.g.slime_default_config`
- `nvim-slimetree` can keep handling statement, form, and region sends

That means the split of responsibility is:

- `ark.nvim`: pane lifecycle, bridge bootstrap, LSP startup, status
- `vim-slime`: transport into tmux
- `nvim-slimetree`: R-aware send motions and textobject-style execution

If you use Blink, keep using its normal `lsp` source. `ark.nvim` is designed to work through standard LSP completion rather than a custom completion source.

## Commands

The plugin defines:

- `:ArkPaneStart`
- `:ArkPaneRestart`
- `:ArkPaneStop`
- `:ArkTabNew`
- `:ArkTabNext`
- `:ArkTabPrev`
- `:ArkTabClose`
- `:ArkTabList`
- `:ArkTabGo`
- `:ArkLspStart`
- `:ArkHelp`
- `:ArkHelpPane`
- `:ArkRefresh`
- `:ArkStatus`
- `:ArkPaneCommand`
- `:ArkBuildLsp`

Useful ones in practice:

- `:ArkStatus` prints the current pane, launcher, and bridge state
- `:ArkRefresh` restarts the current buffer's LSP client using current session metadata
- `:ArkHelp` opens a read-only floating help page for the symbol under cursor
- `:ArkPaneCommand` prints the exact launcher command used for the managed pane
- `:checkhealth ark` reports install/runtime prerequisites without starting a session

## Verification

For a single branch-confidence run, use:

```sh
just verify
```

That wrapper runs `cargo nextest`, `cargo clippy`, rebuilds `ark-lsp` once, and
then executes the Neovim E2E suite serially through `scripts/run-e2e-test.sh`.
It is the intended one-shot command when tmux-backed E2Es require a single
escalated run outside the sandbox.

## Defaults

Current defaults from `require("ark").setup()` are:

```lua
require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = false,
  configure_slime = true,
  filetypes = { "r", "rmd", "qmd", "quarto" },
  tmux = {
    pane_layout = "auto",
    stacked_max_width = 100,
    pane_percent = 33,
    stacked_pane_percent = 50,
  },
})
```

By default the plugin will try these `ark-lsp` locations in order:

1. `ARK_NVIM_LSP_BIN`
2. `target/debug/ark-lsp` inside the plugin checkout
3. `target/release/ark-lsp` inside the plugin checkout
4. `ark-lsp` on your `PATH`

The managed R pane uses the repo-local launcher:

```sh
scripts/ark-r-launcher.sh
```

That launcher installs the vendored `packages/arkbridge` bridge package into the
first writable directory from the session's normal `.libPaths()` by default, or
into `ARK_NVIM_SESSION_LIB` when you explicitly set one.

and writes trusted readiness metadata under:

```text
stdpath("state") .. "/ark-status"
```

Pane layout defaults are geometry-aware:

- narrow tmux windows at or below `100` columns: stacked top/bottom at `50%`
- taller-than-wide tmux windows: stacked top/bottom at `50%`
- otherwise: side-by-side at `33%`

You can override that explicitly:

```lua
require("ark").setup({
  tmux = {
    pane_layout = "side_by_side", -- or "stacked" / "auto"
    stacked_max_width = 100,
    pane_percent = 33,
    stacked_pane_percent = 50,
  },
})
```

## Environment Knobs

The main overrides are:

- `ARK_NVIM_R_BIN`
- `ARK_NVIM_R_ARGS`
- `ARK_NVIM_LSP_BIN`
- `ARK_NVIM_LAUNCHER`
- `ARK_NVIM_SESSION_LIB` (optional override for a dedicated bridge library)
- `ARK_NVIM_SESSION_PKG_PATH`
- `ARK_STATUS_DIR`

Pane width respects the first tmux setting it finds from:

- `TMUX_CODING_PANE_WIDTH`
- `TMUX_JOIN_WIDTH`
- `GOOTABS_JOIN_WIDTH`

## Build Notes

The workspace targets Rust `1.94`. If your installed `stable` toolchain is older, update it first:

```sh
rustup update stable
```

For quick local sanity, a headless load looks like:

```sh
nvim --headless -u NONE \
  -c "set rtp+=/path/to/ark.nvim" \
  -c "lua require('ark').setup({ auto_start_pane = false, auto_start_lsp = false })" \
  -c "lua vim.print(require('ark').status())" \
  -c "qa!"
```

## Repo Status

The direction is settled even though retained upstream code still exists in-tree:

- `ark.nvim` is the Neovim plugin surface
- `ark-lsp` is the stdio server Neovim should run
- tmux is the canonical home of the interactive R session
- `nvim-slimetree` plus `vim-slime` remain the execution layer

The old upstream Ark kernel and Positron code still exists in-tree as extraction material, not as the intended user-facing product.

## See Also

- [BUILDING.md](BUILDING.md)
- [SPEC.md](SPEC.md)
- [AGENTS.md](AGENTS.md)

## License

MIT.
