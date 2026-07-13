ark.nvim
========

`ark.nvim` is a Neovim R workstation built around a real interactive `R`
session. It gives Neovim a fast Rust LSP, manages one local R session for you,
and lets editor features use that live session when static analysis is not
enough.

It is designed for the workflow many R users already like:

- keep an R REPL visible in tmux or a Neovim terminal split
- send code with `nvim-slimetree` and `vim-slime`
- get LSP completion, diagnostics, hover, signature help, symbols, references,
  folding, and selection ranges in `R`, `Rmd`, `Qmd`, and Quarto buffers
- inspect live objects with `:ArkView`
- open help with `:ArkHelp`
- work with `{targets}` projects through completions, navigation, target
  metadata, and local build/load/invalidate actions

The result should feel like a local R development environment, not a notebook
runtime. Your REPL remains a normal R process, your editor remains Neovim, and
Ark connects the two where language features need runtime knowledge.

## What It Feels Like

Open an R-family buffer and Ark starts or reuses one managed R session. Static
language features appear first, then live-session features hydrate as soon as R
is ready.

In practice that means Ark can help with:

- package names and installed-package lookups
- `$`, `@`, `[[`, subset, and comparison-string completions
- function signatures and help pages
- `browser()` frame locals
- R Markdown and Quarto fenced chunks
- inline `` `r ...` `` expressions
- live data-frame inspection through `:ArkView`
- `{targets}` target names, definitions, cached object members, metadata, graph
  views, and target actions

If the R session is not ready, Ark keeps working in static-only mode rather
than blocking the editor.

For first-run verification, open an R file and run:

```vim
:checkhealth ark
:Ark status
```

The normal live destination is `product_state = "live_ready"`. If it is still
starting, static features remain available. See
[troubleshooting](docs/troubleshooting.md) for every state and recovery path.

## Main Workflows

### Edit and Send Code

`ark.nvim` manages the R session and points your send-code tools at it. It does
not replace `vim-slime` or `nvim-slimetree`.

The common split is:

- `ark.nvim`: session lifecycle, bridge bootstrap, LSP startup, status
- `vim-slime`: transport into the active R backend
- `nvim-slimetree`: R-aware sends for forms, lines, chunks, and selections

### Complete and Navigate R Code

Ark uses Neovim's normal LSP client. With Blink, keep using Blink's built-in
`lsp` source. There is no separate Ark completion source to install.

Supported editor features include diagnostics, completion, completion resolve,
hover, signature help, definitions, references, implementations, document
symbols, workspace symbols, folding ranges, selection ranges, limited code
actions, and newline-triggered indentation.

### Inspect Data

`:ArkView` opens a live table explorer for the expression under cursor or an
explicit expression. It can page, sort, filter, inspect cells, show column
profiles, export the current view, and display the R code behind the active
view.

### Work With `{targets}`

In `{targets}` projects, Ark can complete target names, jump to target
declarations, show references, inspect target metadata, complete cached target
object members, and run approved local target actions. Ark uses `_targets.R` by
default and also honors targets script settings from `_targets.yaml`.

## What It Is Not

`ark.nvim` intentionally does not try to be:

- a Jupyter kernel
- a notebook execution environment
- a Positron frontend
- a DAP/debugger integration
- a replacement for `vim-slime` or `nvim-slimetree`
- a remote or multi-host tmux orchestration layer

## How It Works

There are three moving parts:

- `ark-lsp`, a native Rust language server that Neovim starts over stdio
- the Neovim plugin, which starts or reuses one managed R session
- a local bridge that lets `ark-lsp` ask that R session for runtime-aware facts

The R session does not live inside the LSP process. tmux is the primary session
backend, and a narrower built-in Neovim terminal backend is available when you
do not want to run Neovim inside tmux.

## Prerequisites

You need:

- Neovim `0.11.3` or newer with built-in LSP support
- `R >= 4.2`
- the R package `jsonlite`
- `curl` and `sha256sum` for the release installer
- the Tree-sitter parsers needed by `nvim-slimetree` for send-current mappings
  such as normal-mode `<CR>` and `<leader><CR>`; at minimum, `.R` buffers need
  the `r` parser

For the default tmux backend, you also need `tmux`, and Neovim must itself be
running inside tmux. If you set `session.backend = "terminal"`, Ark uses a
managed Neovim terminal split instead. The terminal backend supports the same
LSP and bridge contract, but tmux-only features such as Ark tabs are not
available there.

On Linux, install `inotify-tools` so Neovim can keep Ark's default workspace
file watching responsive. Without it, Neovim uses a recursive per-directory
fallback that can block startup in large projects. `:checkhealth ark` reports
whether the efficient backend is available.

For `{targets}` workflows, install the R package `targets`. `data.table` is
optional but improves coverage for data-table shaped completion and inspection
workflows when your project uses it.

The checked-in Docker README harness pins Neovim `v0.12.1` and also exercises
the minimum supported `0.11` release line in product CI.

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

The planned normal install downloads an optimized, checksummed `ark-lsp`
release into Neovim's data directory without Rust or Cargo. Release status:
`v0.1.0-alpha.1` has not yet been tagged or published, so the runnable setup
below deliberately tracks `main`, builds `ark-lsp` from source, and requires
the pinned Rust toolchain described in [BUILDING.md](BUILDING.md).

If you already run another R LSP such as `r_language_server`, disable it for
`r`, `rmd`, `qmd`, and `quarto` first. `ark.nvim` is meant to be the only R LSP
client for those buffers.

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
- `<leader>rV`, `<leader>tv`, `<leader>r?`, and `<leader>as` for ArkView,
  target ArkView, help, and snippets
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
    dependencies = { "Saghen/blink.lib" },
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
    branch = "main",
    ft = { "r", "rmd", "qmd", "quarto" },
    dependencies = {
      "Saghen/blink.cmp",
      "jpalardy/vim-slime",
      "conig/nvim-slimetree",
    },
    build = "cargo build -p ark-lsp",
    init = function()
      vim.env.ARK_NVIM_DEV_MODE = "1"
    end,
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

The planned first channel is `alpha`. After `v0.1.0-alpha.1` is published,
replace the `branch`, `build`, and `init` entries above with the exact-tag
release lane:

```lua
version = "v0.1.0-alpha.1",
build = function()
  local ok, err = require("ark.release").install_sync()
  if not ok then
    error(err, 0)
  end
end,
```

Published installs must pin an exact release tag; tracking `main` while
installing a tagged `ark-lsp` would violate Ark's exact plugin/LSP/bridge
compatibility contract. To upgrade, change `version` to the next published tag,
sync the plugin so its build hook installs the matching artifact, then run
`:Ark pane restart` and `:Ark refresh`.

Rollback is also a whole-product operation. Pin `version` to the previous tag
and sync/restart the plugin first. The build hook normally activates the
matching binary during that sync. If your plugin manager does not run the build
hook, load the previous plugin checkout and run `:Ark rollback`; Ark refuses to
activate `previous` unless its product version, target, release profile, and
bridge schema match that plugin release.

### Local checkout

If you are developing from a local clone instead of GitHub, use
`dir = "~/repos/ark.nvim"` in the `lazy.nvim` spec. Contributors can retain the
source-build path explicitly:

```lua
{
  dir = "~/repos/ark.nvim",
  build = "cargo build -p ark-lsp",
  init = function()
    vim.env.ARK_NVIM_DEV_MODE = "1"
  end,
}
```

The repository pins the development compiler to Rust `1.97.0` and the
formatting toolchain to `nightly-2025-07-18`. A normal user install does not use
either toolchain. Use `cargo build --release -p ark-lsp` for an optimized manual
source fallback when no release artifact exists for your platform.

## REPL Workflow

`ark.nvim` does not replace your send-code workflow. It manages the R session
and points `vim-slime` / `nvim-slimetree` at the correct backend target.

With `configure_slime = true`:

- `ark.nvim` starts or reuses the managed R session
- `ark.nvim` updates the backend-specific send target
- R-family `vim-slime` sends revalidate that target first, so a closed managed
  pane is relaunched before the original code is sent
- `nvim-slimetree` can keep handling statement, form, and region sends

That means the split of responsibility is:

- `ark.nvim`: session lifecycle, bridge bootstrap, LSP startup, status
- `vim-slime`: transport into the active backend
- `nvim-slimetree`: R-aware send motions and textobject-style execution

If you use Blink, keep using its normal `lsp` source. `ark.nvim` is designed to
work through standard LSP completion rather than a custom completion source.

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
- `:ArkInstallMissingPackages` for missing-package diagnostics
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
With the tmux backend, ArkView opens every editor-, console-, and target-driven
view in a centered tmux popup by default. Set `view.display = "tab"` to keep the
explorer in the current Neovim instance instead. If a selected popup cannot be
launched, Ark reports the launch error rather than silently opening a tab.
When the grid is scrolled vertically, ArkView keeps the column header visible
above the first visible row.

Inside ArkView, use `<` and `>` to narrow or widen the selected column, `=` to
enter an exact width, and `w` to wrap or unwrap the selected column at its
current width. By default, ArkView sizes columns from the visible values up to
200 cells per column, so wide tables may extend past the current window instead
of clipping ordinary long strings. The same controls are available as commands:

```vim
:Ark view width 60
:Ark view width +8 column_name
:Ark view width reset column_name
:Ark view wrap on column_name
:Ark view wrap off column_name
```

## Target Workflows

Ark treats `{targets}` projects as an editor workflow rather than just another
set of R function calls. In a project with a configured targets script, Ark can:

- complete target names in common target-reading and target-building calls
- jump from target references to static target declarations
- show target references across project files
- complete members and columns from cached target objects, such as
  `targets::tar_read(clean_data)$`
- open target graph, status, metadata, and log views
- pick and remember an active target for repeated build/load actions
- run approved local actions such as build, build downstream, and invalidate
- send `targets::tar_load(...)` to the managed pane so loaded targets appear in
  the pane's active R context

The design is deliberately narrow: Ark does not reimplement `{targets}` or
invent a separate pipeline runner. Static analysis discovers what it can from
project files, and the bridge asks the live R session for manifest, cache, and
object facts when those facts require `{targets}` itself.

## Commands

The commands you will usually reach for are:

- `:Ark status` prints the current pane, launcher, and bridge state
- `:Ark report` previews a redacted support report without embedding source or R values
- `:Ark refresh` restarts the current buffer's LSP client using current session metadata
- `:Ark help` opens a read-only floating help page for the symbol under cursor
- `:Ark view` opens the live data explorer for an expression or the symbol under cursor
- `:Ark send` sends text to the active managed Ark R session
- `:Ark snippets` opens the explicit Ark snippets picker
- `:Ark packages install-missing` installs packages from current missing-package
  diagnostics, using `pak` and DESCRIPTION remotes when available
- `:Ark pane start`, `:Ark pane restart`, and `:Ark pane stop` manage the R session
- `:Ark pane command` prints the exact launcher command used for the managed pane
- `:checkhealth ark` reports install/runtime prerequisites without starting a session

For `{targets}` projects:

- `:Ark targets info` and `:Ark targets manifest` show project and
  manifest state
- `:Ark targets graph`, `:Ark targets network`, `:Ark targets status`,
  `:Ark targets meta`, and `:Ark targets log` open target views
- `:Ark targets pick` selects and remembers an active `{targets}` target
- `:Ark targets view` picks a target and opens `targets::tar_read(...)` in
  ArkView
- `:Ark targets load-pick` / `:Ark targets build-pick` pick a target and run
  the matching target operation
- `:Ark targets load-active` / `:Ark targets build-active` run the operation
  for the remembered active target
- `:Ark targets build-downstream`, `:Ark targets invalidate`, and related `*-pick`
  variants run the matching local target action

Target pickers use local static declarations for the initial list, so opening
the picker does not wait for `targets::tar_manifest()`. With Snacks available,
the picker shows targets above a preview of the declaration that created the
selected target.

The plugin also defines legacy `:ArkStatus`, `:ArkPaneStart`, `:ArkTarget*`,
and related commands for compatibility after it is loaded. Use Neovim completion
on `:Ark` to discover the full dispatcher command set available in your current
build.

## Verification

For a single branch-confidence run, use:

```sh
just verify-product
```

That required product gate checks the pinned release manifest/toolchains,
product Rust crates, `arkbridge`, release installer contracts, and focused
Neovim product smokes. `just verify` remains the broader serial full-confidence
suite, while `just verify-upstream-compat` explicitly exercises the retained
upstream workspace.

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

The wrapper packages the same optimized release artifact used by CI, then
builds an Ubuntu 24.04 image with no Rust compiler or Cargo. The image installs the
checksummed artifact through Ark's normal installer, installs the
README-minimal plugins and Debian R dependencies, and bakes in the Tree-sitter
`r` and `markdown` parsers needed by the isolated config. It currently pins
Neovim `v0.12.1`.

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
    console_frontend = "raw",
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
2. the current checksummed release under `stdpath("data") .. "/ark"`
3. `ark-lsp` on your `PATH`
4. `target/release/ark-lsp` as an explicit source-build fallback

Set `ARK_NVIM_DEV_MODE=1` for a contributor checkout. Only that explicit mode
allows `target/debug/ark-lsp` to take precedence over the installed release.
`:Ark rollback` and `:ArkRollback` activate the previous installed binary only
after the plugin checkout has been pinned to that same release; this prevents a
mixed-version product.

After an upgrade or rollback, run `:Ark pane restart` and `:Ark refresh` so the
plugin, LSP, and bridge all use the same product version. The current support
table is in [docs/compatibility.md](docs/compatibility.md).

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

Ark has two managed-console frontend modes:

- `raw`, the default, runs the launcher directly in the managed tmux pane or
  Neovim terminal split.
- `nvim-console` runs a Neovim-buffer R console. In-process, open it with
  `:Ark console`; in a managed tmux split, Ark launches the `scripts/ark-console`
  wrapper, which starts Neovim and runs `:Ark console`.

To use the Neovim-buffer console frontend:

```lua
require("ark").setup({
  session = {
    console_frontend = "nvim-console",
  },
})
```

The `nvim-console` frontend keeps the editable input region as a normal R
buffer, so Blink's regular `lsp` source works without a separate completion
source. Ark draws the prompt virtually, preserves submitted input as R code, and
records R output as `#>` transcript comments. Its standalone init also loads a
lazy-installed `nvim-autopairs` when available, so normal quote and bracket
pairing works in the REPL. The raw launcher remains the default fallback.

The standalone REPL sources optional user configuration from
`~/.config/ark.nvim/ark-repl/init.lua` by default. That directory is added to
the REPL Neovim runtimepath first, so modules under its `lua/` directory are
available to `require()`. Set `ARK_NVIM_REPL_CONFIG_DIR` to use a different
directory.

## Environment Knobs

The main overrides are:

- `ARK_NVIM_R_BIN`
- `ARK_NVIM_R_ARGS`
- `ARK_NVIM_LSP_BIN`
- `ARK_NVIM_LAUNCHER`
- `ARK_NVIM_SESSION_LIB` (optional override for a dedicated bridge library)
- `ARK_NVIM_SESSION_BACKEND` (`tmux` or `terminal`)
- `ARK_NVIM_SESSION_KIND`
- `ARK_NVIM_CONSOLE_FRONTEND` (`raw` or `nvim-console`)
- `ARK_NVIM_CONSOLE_BIN` (default: repo-local `scripts/ark-console`, then Neovim)
- `ARK_NVIM_CONSOLE_COMMAND` (default: `Ark console`)
- `ARK_NVIM_CONSOLE_INIT` (optional `-u` init file for the standalone
  `ark-console` Neovim process)
- `ARK_NVIM_REPL_CONFIG_DIR` (optional user config directory for the standalone
  `nvim-console` process; default: `~/.config/ark.nvim/ark-repl`)
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

The workspace pins Rust `1.97.0`. If that toolchain is not installed, let
rustup install it from `rust-toolchain.toml`:

```sh
rustup toolchain install 1.97.0
```

For quick local sanity, a headless load looks like:

```sh
nvim --headless -u NONE \
  -c "set rtp+=/path/to/ark.nvim" \
  -c "lua require('ark').setup({ auto_start_pane = false, auto_start_lsp = false })" \
  -c "lua vim.print(require('ark').status())" \
  -c "qa!"
```

## Project Notes

This repository started as a fork of upstream Ark, whose primary product is an
R kernel and language stack for Positron and Jupyter clients. `ark.nvim` keeps
the reusable R analysis work, but the supported user-facing product here is the
Neovim workflow described above:

- `ark.nvim` is the plugin surface
- `ark-lsp` is the stdio server Neovim should run
- one managed local R session provides runtime context
- `nvim-slimetree` plus `vim-slime` remain the execution layer

Some upstream kernel, Positron, and DAP-oriented code still exists in-tree while
the Neovim product boundary continues to settle. It is not the default runtime
path for users installing this plugin.

## See Also

- [BUILDING.md](BUILDING.md)
- [SPEC.md](SPEC.md)
- [AGENTS.md](AGENTS.md)
- [Native `:help ark` reference](doc/ark.txt)
- [Troubleshooting and support reports](docs/troubleshooting.md)
- [Compatibility and upgrades](docs/compatibility.md)
- [Product architecture](docs/architecture.md)

## License

MIT.
