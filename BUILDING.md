## Building

The workspace currently declares `rust-version = "1.89"`.

On this machine, `stable` is `1.88.0`, so the practical development path is:

```sh
cargo +nightly check -p ark --bin ark-lsp
```

If your stable toolchain is already `1.89+`, ordinary `cargo` commands are fine.

## Useful Commands

Build or check the standalone LSP:

```sh
cargo +nightly check -p ark --bin ark-lsp
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
- The managed-pane launcher lives at `scripts/ark-r-launcher.sh`.
