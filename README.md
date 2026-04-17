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
- standard LSP features such as diagnostics, completion, hover, signature help,
  definitions, references, implementations, symbols, folding ranges, selection
  ranges, and limited code actions
- live-session completion, hover, signature help, help text, and data-explorer
  workflows when the managed R session is available

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

## Ark LSP Feature Matrix

The table below reflects the current `ark-lsp` surface in this repository,
including Ark-specific custom methods used by the Neovim plugin.

| Surface | Status | Notes |
| --- | --- | --- |
| Diagnostics | Supported | Syntax diagnostics are available immediately; semantic diagnostics hydrate after detached session state is ready. |
| Completion | Supported | Static and live-session completion; includes package/library, subset/comparison string, browser-frame, and Rmd/Qmd support. |
| Completion item resolve | Supported | Completion docs/detail resolution is implemented. |
| Hover | Supported | Static hover works detached; runtime-aware hover is added when the managed session is available. |
| Signature help | Supported | Static plus runtime-aware signature help. |
| Definition | Supported | Workspace-aware static definition lookup. |
| Implementation | Supported | Advertised and handled by the LSP server. |
| References | Supported | Workspace-aware static reference lookup. |
| Document symbols | Supported | Per-document symbol outline is implemented. |
| Workspace symbols | Supported | Workspace-wide symbol search is implemented. |
| Folding ranges | Supported | Standard folding range support is advertised. |
| Selection ranges | Supported | Standard selection range support is advertised. |
| Code actions | Limited | Exposed only when the client supports code-action literals; current support is intentionally narrow. |
| On-type formatting | Limited | Newline-triggered indentation support only. |
| Workspace folders | Supported | Workspace folder support and change notifications are advertised. |
| File create/delete/rename notifications | Supported | Watches `*.R` file operations for workspace updates. |
| R Markdown / Quarto fenced chunks | Supported | Completion and diagnostics work in fenced R chunks. |
| R Markdown / Quarto inline `` `r ...` `` | Supported | Inline R completion is implemented. |
| `ark/textDocument/helpTopic` | Supported | Ark-native help-topic request used by the plugin help UI. |
| `ark/textDocument/statementRange` | Supported | Ark-native statement-range request. |
| `ark/inputBoundaries` | Supported | Ark-native input-boundaries request. |
| `ark/internal/bootstrapSession` | Supported, internal | Plugin-only detached-session bootstrap path. |
| `ark/updateSession` | Supported, internal | Plugin notification used to refresh detached session metadata. |
| `ark/internal/status` | Supported, internal | Plugin status/debug request. |
| `ark/internal/helpText` | Supported, internal | Plugin request for full help-page text. |
| `ark/internal/virtualDocument` | Supported, internal | Plugin/internal virtual-document request. |
| `ark/internal/view*` data explorer RPCs | Supported, internal | Back the `ArkView` live data explorer workflow. |
| Rename | Not supported | No rename provider is advertised. |
| Type definition | Not supported | `typeDefinitionProvider` is currently `None`. |
| Declaration | Not supported | No declaration provider is advertised. |
| Document formatting / range formatting | Not supported | Only on-type formatting is implemented. |
| Semantic tokens | Not supported | No semantic tokens provider is advertised. |
| Inlay hints | Not supported | No inlay hint provider is advertised. |
| Call hierarchy | Not supported | No call hierarchy provider is advertised. |
| Code lens | Not supported | No code lens provider is advertised. |
| Public execute commands | Not supported | The server advertises an empty execute-command list. |

## Prerequisites

You need:

- Neovim with built-in LSP support
- `tmux`, and Neovim must itself be running inside tmux
- `R >= 4.2`
- the R package `jsonlite`
- the Tree-sitter parsers needed by `nvim-slimetree` for send-current mappings
  such as normal-mode `<CR>` and `<leader><CR>`; at minimum, `.R` buffers need
  the `r` parser
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

The minimal recommended `lazy.nvim` setup keeps:

- `blink.cmp` as the completion UI using its normal `lsp` source
- `nvim-autopairs` for delimiter pairing, with `map_cr = false`
- `nvim-slimetree` plus `vim-slime` as the send path from buffer to REPL
- `ark.nvim` as the pane/LSP/session layer

The simplest version is to let the plugin build `ark-lsp` inside its own checkout, then let `ark.nvim` find `target/debug/ark-lsp` automatically.

If you already run another R LSP such as `r_language_server`, disable it for `r`, `rmd`, `qmd`, and `quarto` first. `ark.nvim` is meant to be the only R LSP client for those buffers.

This recommended setup also includes the basic send-code mappings through
`nvim-slimetree`:

- Normal `<CR>` sends the current R form
- Normal `<leader><CR>` sends the current R form and keeps the cursor in place
- Normal `<C-c><C-c>` sends the current line
- Visual `<CR>` sends the selected region

The first two are Tree-sitter-based chunk/form sends, so they need the relevant
parser(s) installed. `<C-c><C-c>` is the simpler current-line send.

This recommended config uses `nvim-slimetree` as the send layer and `vim-slime`
as the transport into the managed tmux pane.

If you are not already starting Tree-sitter for these buffers elsewhere in your
config, add the minimal startup glue before the plugin spec:

```lua
local shared_site = vim.fs.normalize(vim.fn.expand("~/.local/share/nvim/site"))
if vim.fn.isdirectory(shared_site) == 1 then
  vim.opt.runtimepath:prepend(shared_site)
end

vim.treesitter.language.register("markdown", "rmd")
vim.treesitter.language.register("markdown", "qmd")
vim.treesitter.language.register("markdown", "quarto")

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "r", "rmd", "qmd", "quarto" },
  callback = function(args)
    local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
      or vim.bo[args.buf].filetype
    pcall(vim.treesitter.start, args.buf, lang)
  end,
})
```

The `runtimepath` prepend is mainly important when you run an isolated config or
override `XDG_DATA_HOME`; it makes sure Neovim can still see parsers installed
under `~/.local/share/nvim/site/parser/`.

```lua
return {
  {
    "Saghen/blink.cmp",
    ft = { "r", "rmd", "qmd", "quarto" },
    config = function()
      require("blink.cmp").setup({
        fuzzy = {
          implementation = "lua",
        },
        completion = {
          documentation = {
            auto_show = true,
          },
        },
        sources = {
          default = { "lsp", "path", "buffer" },
        },
      })
    end,
  },
  {
    "windwp/nvim-autopairs",
    ft = { "r", "rmd", "qmd", "quarto" },
    config = function()
      require("nvim-autopairs").setup({
        map_cr = false,
      })
    end,
  },
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
        transport = {
          backend = "slime",
          async = true,
        },
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
      "Saghen/blink.cmp",
      "jpalardy/vim-slime",
      "conig/nvim-slimetree",
    },
    build = "cargo build -p ark-lsp",
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
- `:ArkView`
- `:ArkViewRefresh`
- `:ArkViewClose`
- `:ArkSnippets`
- `:ArkRefresh`
- `:ArkStatus`
- `:ArkPaneCommand`
- `:ArkBuildLsp`
- `:ArkBuildBridge`

Useful ones in practice:

- `:ArkStatus` prints the current pane, launcher, and bridge state
- `:ArkRefresh` restarts the current buffer's LSP client using current session metadata
- `:ArkHelp` opens a read-only floating help page for the symbol under cursor
- `:ArkView` opens the live data explorer for an expression or the symbol under cursor
- `:ArkSnippets` opens the explicit Ark snippets picker
- `:ArkPaneCommand` prints the exact launcher command used for the managed pane
- `:checkhealth ark` reports install/runtime prerequisites without starting a session

## Verification

For a single branch-confidence run, use:

```sh
just verify
```

That wrapper runs `cargo nextest`, `cargo clippy`, rebuilds `ark-lsp` from the
dedicated `ark-lsp` package once, and
then executes the Neovim E2E suite serially through `scripts/run-e2e-test.sh`
using the checked-in Blink-backed fixture at
`tests/e2e/init.lua`.

For extra ambient-user-config coverage, override the init explicitly:

```sh
./scripts/run-full-suite.sh --init ~/.config/nvim/init.lua
```

To exercise the README-recommended minimal config directly, use:

```sh
./scripts/start-readme-test-nvim.sh
```

For a headless smoke run of that same config, use:

```sh
./scripts/smoke-readme-test-config.sh
```

That harness lives under `testing/readme-minimal/` and uses the same Blink +
`nvim-slimetree` + `vim-slime` + `ark.nvim` stack documented above.

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
- `ARK_NVIM_SESSION_KIND`
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
