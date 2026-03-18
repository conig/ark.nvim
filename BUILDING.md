## Building

The workspace currently declares `rust-version = "1.89"` and defaults to the
`stable` Rust channel via `rust-toolchain.toml`.

If your installed `stable` toolchain is older than `1.89`, update it first:

```sh
rustup update stable
```

After that, ordinary `cargo` commands are fine.

## Useful Commands

Build or check the standalone LSP:

```sh
cargo check -p ark --bin ark-lsp
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
- `ark-lsp` currently defaults to `--runtime-mode detached`.
- The Neovim plugin uses the repo-local `scripts/ark-r-launcher.sh` launcher.
- The managed pane bootstraps the vendored `packages/rscope` runtime into `stdpath("data") .. "/ark/r-lib"` by default.
- Use `:ArkRefresh` after the managed pane becomes ready if you want to restart the buffer LSP with fresh session bridge metadata.
- Formatting still uses nightly-only `rustfmt` options today, so `cargo fmt` is not yet a stable-only workflow.
