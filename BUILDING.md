## Building

The workspace MSRV is `rust-version = "1.94"`. This checkout pins ordinary
development and release-verification commands to Rust `1.97.0` through
`rust-toolchain.toml` so contributors use the same compiler.

Install the pinned development toolchain if rustup has not already done so:

```sh
rustup toolchain install 1.97.0 --profile minimal --component clippy
```

After that, ordinary `cargo` commands use `1.97.0`. Formatting is separately
pinned because the workspace rustfmt settings require nightly features:

```sh
rustup toolchain install nightly-2025-07-18 --profile minimal --component rustfmt
cargo +nightly-2025-07-18 fmt --all
```

## Useful Commands

Build or check the standalone LSP:

```sh
cargo check -p ark-lsp
```

Build the legacy upstream kernel binary only when you explicitly need it:

```sh
cargo build -p ark --features legacy-kernel-bin --bin ark
```

Run the full confidence suite:

```sh
just verify
```

Headless-load the Neovim plugin:

```sh
nvim --headless -u NONE \
  -c "set rtp+=/path/to/ark.nvim" \
  -c "lua require('ark').setup({ auto_start_pane = false, auto_start_lsp = false })" \
  -c "lua vim.print(require('ark').status())" \
  -c "qa!"
```

Print the pane launcher command from Neovim:

```vim
:ArkPaneCommand
```

## Notes

- The repo still contains upstream Ark crates that are not part of the intended v1 Neovim product.
- The legacy `ark` kernel binary is no longer part of the default workspace build.
- `ark-lsp` currently defaults to `--runtime-mode detached`.
- The Neovim plugin uses the repo-local `scripts/ark-r-launcher.sh` launcher.
- The managed pane bootstraps the vendored `packages/arkbridge` runtime into the first writable library path by default, or `ARK_NVIM_SESSION_LIB` when set.
- Use `:ArkRefresh` after the managed pane becomes ready if you want to restart the buffer LSP with fresh session bridge metadata.
- Use `:checkhealth ark` to inspect prerequisites and binary discovery without starting a pane or LSP.
- Formatting uses the exact nightly toolchain shown above; do not rely on an
  ambient `nightly` alias.
