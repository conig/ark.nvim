ark.nvim
========

`ark.nvim` turns Ark's R analysis engine into a Neovim-native R
environment. It is built around three pieces:

- `ark-lsp`, a native Rust language server for R
- a Neovim plugin that starts or reuses one managed interactive `R` session,
  with tmux as the primary backend and a narrower built-in terminal backend
- a local bridge that lets language features ask the live R session questions
  without moving the REPL into the LSP process

The goal is not to recreate Positron or Jupyter inside Neovim. The goal is a
fast local R workflow where editing, static analysis, the interactive REPL,
object inspection, help, and `{targets}` iteration all meet inside the editor
while preserving the terminal-shaped workflow that R users already trust.

This repo started as upstream Ark, so it still contains kernel, Positron, DAP,
and other migration-era code. That is not the product surface anymore. The
active product is a local, Neovim-only workflow where:

- Neovim talks to `ark-lsp` over stdio.
- The live R session stays in one configured managed backend.
- Runtime-aware features cross that boundary through the managed bridge.
- REPL execution stays with `nvim-slimetree` and `vim-slime`.
- Ark-specific UI lives in Neovim commands such as `:ArkHelp`, `:ArkView`, and
  the `:ArkTarget*` command family.

The legacy `ark` kernel binary is retained only as an opt-in extraction artifact.
Default builds and the supported runtime path target `ark-lsp`.

## User Experience

The intended daily loop is:

1. Open an `r`, `rmd`, `qmd`, or `quarto` buffer.
2. `ark.nvim` starts or reuses one managed R session.
3. Static LSP features become available immediately.
4. Once the managed R session is ready, completion, hover, signature help,
   diagnostics, help, and object inspection can use live session state.
5. Code execution still goes through `nvim-slimetree` and `vim-slime`, so
   statement, chunk, line, and region sends continue to behave like a normal
   REPL workflow.
6. For `{targets}` projects, Ark can surface target names, target definitions,
   cache metadata, build/load/invalidate commands, and target-object member
   completion without making `{targets}` itself part of the editor.

This means Ark can complete things like package names, `$` members, `[[` names,
comparison-string values, `browser()` frame locals, R Markdown inline code, and
cached target object columns while keeping the REPL visible and under user
control.

## Upstream Difference

Upstream Ark is an R kernel for Jupyter applications and Positron. It presents
the LSP and DAP as pieces of that frontend/kernel stack.

`ark.nvim` keeps the reusable R analysis pieces but changes the product
boundary:

| Area | Upstream Ark | `ark.nvim` |
| --- | --- | --- |
| Primary frontend | Positron and Jupyter clients | Neovim |
| Main binary | `ark` kernel | `ark-lsp` stdio LSP |
| Execution model | Kernel owns evaluation | User sends code to a managed interactive `R` REPL |
| Runtime intelligence | Lives with the kernel/session | Crosses a local bridge into the managed REPL |
| Editor UI | Positron/Jupyter surfaces | Neovim commands, LSP, Blink, `vim-slime`, and `nvim-slimetree` |
| Data inspection | Upstream notebook/IDE data explorer paths | `:ArkView` live tabular object explorer |
| Pipeline work | Not the user-facing upstream README story | `{targets}` completions, metadata, graph/status views, and target actions |
| Debugging | Upstream DAP code exists | Out of scope for the Neovim product |
| Notebook runtime | Core upstream use case | Out of scope |

The result is a fork with a different user promise: a Neovim R workstation, not
a Jupyter kernel distribution.

## Scope

`ark.nvim` is for:

- Neovim R development.
- One managed tmux R pane per Neovim instance.
- One managed Neovim terminal R split per Neovim instance when the terminal
  backend is selected.
- Standard LSP features such as diagnostics, completion, hover, signature help,
  definitions, references, implementations, symbols, folding ranges, selection
  ranges, and limited code actions.
- Live-session completion, hover, signature help, help text, and ArkView
  workflows when the managed R session is available.
- R Markdown and Quarto editing, including fenced R chunks and inline
  `` `r ...` `` expressions.
- `{targets}` project navigation, completion, metadata, and approved local
  actions when the `targets` package is installed.

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
2. `ark.nvim` creates or reuses one managed backend running `R`.
3. `nvim-slimetree` and `vim-slime` send code to that session.
4. `ark-lsp` provides static language features through Neovim's built-in LSP client.
5. When the managed R session is ready, `ark-lsp` augments static analysis with live-session intelligence through the bridge runtime.

The important boundary is that the REPL does not live inside the LSP process.
`ark.nvim` manages the session backend, the launcher bootstraps the bridge
runtime, and the LSP consumes that session metadata when it starts in detached
mode. tmux remains the primary UX, and the built-in terminal backend is
additive rather than a new least-common-denominator abstraction.

## Ark LSP Feature Matrix

The table below reflects the current `ark-lsp` surface in this repository,
including Ark-specific custom methods used by the Neovim plugin.

| Surface | Status | Notes |
| --- | --- | --- |
| Diagnostics | Supported | Syntax diagnostics are available immediately; semantic diagnostics hydrate after detached session state is ready. |
| Completion | Supported | Static and live-session completion; includes package/library, extractor, subset/comparison string, browser-frame, target-object, and Rmd/Qmd support. |
| Completion item resolve | Supported | Completion docs/detail resolution is implemented. |
| Hover | Supported | Static hover works detached; runtime-aware hover is added when the managed session is available. |
| Signature help | Supported | Static plus runtime-aware signature help. |
| Definition | Supported | Workspace-aware static definition lookup. |
| Implementation | Supported | Advertised and handled by the LSP server. |
| References | Supported | Workspace-aware static reference lookup. |
| `{targets}` target definition | Supported | Static target references can jump to declarations in `_targets.R` and sourced target pipeline files. |
| `{targets}` completions/actions | Supported | Target names, cached target object members, cache metadata, graph/status views, and build/load/invalidate actions are exposed through Ark requests and commands. |
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
| `ark/internal/targets*` target RPCs | Supported, internal | Back the `{targets}` command and completion workflows. |
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

- Neovim `0.12.1` or newer with built-in LSP support
- `R >= 4.2`
- the R package `jsonlite`
- the Tree-sitter parsers needed by `nvim-slimetree` for send-current mappings
  such as normal-mode `<CR>` and `<leader><CR>`; at minimum, `.R` buffers need
  the `r` parser
- a Rust toolchain capable of building the workspace (`rust-version = 1.94`)

For the default tmux backend, you also need `tmux`, and Neovim must itself be
running inside tmux. If you set `session.backend = "terminal"`, Ark uses a
managed Neovim terminal split instead. The terminal backend supports the same
LSP and bridge contract, but tmux-only features such as Ark tabs are not
available there.

For `{targets}` workflows, install the R package `targets`. `data.table` is
optional but improves coverage for data-table shaped completion and inspection
workflows when your project uses it.

The checked-in Docker README harness pins the same current stable Neovim release
(`v0.12.1`) so the documented container path matches the supported editor floor.

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
as the transport into the managed session. With the default tmux backend,
`ark.nvim` writes the tmux target into `vim-slime`. With the terminal backend,
it publishes terminal job metadata for terminal-native sends.

If you want ark.nvim to install the same basic R workflow mappings for
R-family buffers, enable the optional keymap preset:

```lua
require("ark").setup({
  keymaps = true,
})
```

That preset includes:

- Normal `<CR>` to send the current R form
- Normal `<leader><CR>` to send the current R form without moving the cursor
- Normal `<C-c><C-c>` to send the current line
- Visual `<CR>` to send the selected region
- `<leader>rp` to start or restart the managed R pane
- `<leader>rw` to send the expression under cursor or the selection
- `<leader>rh` / `<leader>rs` to run `head()` / `summary()` on that expression
- `<leader>rV`, `<leader>r?`, and `<leader>as` for ArkView, help, and snippets
- `<leader>r=`, `<leader>r[`, `<leader>r]`, and `<leader>r-` for Ark R tabs
- `<leader>tta` and `<leader>ttn` to pick and show the active Ark target

The preset is off by default so existing Neovim keymaps are not changed unless
you explicitly opt in.

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

`ark.nvim` does not replace your send-code workflow. It manages the R session
and points `vim-slime` / `nvim-slimetree` at the correct backend target.

With `configure_slime = true`:

- `ark.nvim` starts or reuses the managed R session
- `ark.nvim` updates the backend-specific send target
- `nvim-slimetree` can keep handling statement, form, and region sends

That means the split of responsibility is:

- `ark.nvim`: session lifecycle, bridge bootstrap, LSP startup, status
- `vim-slime`: transport into the active backend
- `nvim-slimetree`: R-aware send motions and textobject-style execution

If you use Blink, keep using its normal `lsp` source. `ark.nvim` is designed to work through standard LSP completion rather than a custom completion source.

## Live Intelligence

The detached LSP starts before the live session is necessarily ready. That is
intentional: syntax diagnostics, symbols, folding, workspace indexing, and
static completions do not need to wait for R startup.

When the bridge reports that the managed R session is ready, `ark-lsp` hydrates
session metadata and live features become richer:

- search-path and installed-package completions
- `$`, `@`, `[[`, subset, and comparison-string completions
- `browser()` frame locals
- runtime-aware hover and signature help
- full help text for `:ArkHelp`
- `:ArkView` inspection for live objects
- target cache and target object metadata when a `{targets}` project is active

If the live session is unavailable, Ark should degrade to static-only language
features instead of trying to evaluate through an embedded R runtime.

## ArkView

`:ArkView` opens a live data explorer for the expression under cursor or an
explicit expression:

```vim
:ArkView
:ArkView my_data_frame
```

The explorer is backed by the managed R session. It can page through tabular
objects, sort and filter columns, inspect cell values, show column profiles,
export the current view, and display the R code used for the active view. It is
for quick local inspection, not a replacement for a full IDE data pane.

## Target Workflows

Ark treats `{targets}` projects as an editor workflow rather than just another
set of R function calls. In a project with `_targets.R`, Ark can:

- complete target names in common target-reading and target-building calls
- jump from target references to static target declarations
- show target references across project files
- complete members and columns from cached target objects, such as
  `targets::tar_read(clean_data)$`
- open target graph, status, metadata, and log views
- pick and remember an active target for repeated build/load actions
- run approved local actions such as build, build downstream, invalidate, and
  load

The design is deliberately narrow: Ark does not reimplement `{targets}` or
invent a separate pipeline runner. Static analysis discovers what it can from
project files, and the bridge asks the live R session for manifest, cache, and
object facts when those facts require `{targets}` itself.

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
- `:ArkTargetsInfo`
- `:ArkTargets`
- `:ArkTargetsManifest`
- `:ArkTargetPick`
- `:ArkTargetAcquire`
- `:ArkTargetActive`
- `:ArkTargetGraph`
- `:ArkTargetsNetwork`
- `:ArkTargetStatus`
- `:ArkTargetsMeta`
- `:ArkTargetObjectMeta`
- `:ArkTargetBuild`
- `:ArkTargetBuildPick`
- `:ArkTargetBuildActive`
- `:ArkTargetBuildDownstream`
- `:ArkTargetBuildDownstreamPick`
- `:ArkTargetMake`
- `:ArkTargetInvalidate`
- `:ArkTargetInvalidatePick`
- `:ArkTargetLoad`
- `:ArkTargetLoadPick`
- `:ArkTargetLoadActive`
- `:ArkTargetLog`
- `:ArkSnippets`
- `:ArkSend`
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
- `:ArkTargetPick` selects and remembers an active `{targets}` target
- `:ArkTargetLoadPick` / `:ArkTargetBuildPick` pick a target and run the exact Ark target action
- `:ArkTargetLoadActive` / `:ArkTargetBuildActive` run the action for the remembered active target
- `:ArkSnippets` opens the explicit Ark snippets picker
- `:ArkSend` sends text to the active managed Ark R session
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

For a disposable Docker version of that same harness, use the wrapper:

```sh
./scripts/docker-readme-test.sh
```

By default the wrapper runs auto mode: it builds the image when it is missing,
rebuilds it when the repo context has changed, and otherwise drops directly into
the README-minimal Neovim session.

For a noninteractive smoke run in the container:

```sh
./scripts/docker-readme-test.sh auto smoke
```

That image prebuilds `ark-lsp`, installs the README-minimal plugins, installs
the Debian `r-cran-tidyverse` bundle (which includes `jsonlite`), and bakes in
the Tree-sitter `r` and `markdown` parsers needed by the isolated config. It
currently pins Neovim `v0.12.1`, matching the repo's supported baseline.

The explicit Docker wrapper subcommands are:

```sh
./scripts/docker-readme-test.sh build
./scripts/docker-readme-test.sh update
./scripts/docker-readme-test.sh run
./scripts/docker-readme-test.sh smoke
./scripts/docker-readme-test.sh shell
```

## Defaults

Current defaults from `require("ark").setup()` are:

```lua
require("ark").setup({
  auto_start_pane = true,
  auto_start_lsp = true,
  async_startup = false,
  configure_slime = true,
  filetypes = { "r", "rmd", "qmd", "quarto" },
  session = {
    backend = "tmux",
    kind = "ark",
  },
  keymaps = {
    enabled = false,
    prefix = "<leader>r",
    target_prefix = "<leader>t",
    snippets = "<leader>as",
  },
  tmux = {
    pane_layout = "auto",
    stacked_max_width = 100,
    pane_percent = 33,
    stacked_pane_percent = 33,
  },
  terminal = {
    split_direction = "horizontal",
    split_position = "botright",
    split_size = 15,
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

- narrow tmux windows at or below `100` columns: stacked top/bottom at `33%`
- taller-than-wide tmux windows: stacked top/bottom at `33%`
- otherwise: side-by-side at `33%`

You can override that explicitly:

```lua
require("ark").setup({
  tmux = {
    pane_layout = "side_by_side", -- or "stacked" / "auto"
    stacked_max_width = 100,
    pane_percent = 33,
    stacked_pane_percent = 33,
  },
})
```

To use the built-in terminal backend instead of tmux:

```lua
require("ark").setup({
  session = {
    backend = "terminal",
  },
  terminal = {
    split_direction = "horizontal",
    split_position = "botright",
    split_size = 15,
  },
})
```

The terminal backend is useful when you want the same detached LSP and bridge
model without running Neovim inside tmux. It intentionally does not implement
tmux-only tab parking commands.

## Environment Knobs

The main overrides are:

- `ARK_NVIM_R_BIN`
- `ARK_NVIM_R_ARGS`
- `ARK_NVIM_LSP_BIN`
- `ARK_NVIM_LAUNCHER`
- `ARK_NVIM_SESSION_LIB` (optional override for a dedicated bridge library)
- `ARK_NVIM_SESSION_BACKEND` (`tmux` or `terminal`)
- `ARK_NVIM_SESSION_KIND`
- `ARK_NVIM_SESSION_PKG_PATH`
- `ARK_NVIM_TERMINAL_SPLIT_DIRECTION`
- `ARK_NVIM_TERMINAL_SPLIT_POSITION`
- `ARK_NVIM_TERMINAL_SPLIT_SIZE`
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
