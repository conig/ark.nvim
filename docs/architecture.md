# Ark.nvim product architecture

Ark has three active product layers:

1. `ark-lsp`, a detached Rust stdio LSP that owns documents, static analysis,
   diagnostics, indexing, and protocol handling.
2. A versioned local IPC session bridge, served from the managed R process, for
   runtime completions, hover, signatures, help, ArkView, and target cache facts.
3. The Neovim plugin, which owns configuration, backend lifecycle, LSP launch,
   status, health, support reporting, and editor UI.

The R session never lives inside the LSP. Tmux is the canonical backend; the
built-in terminal backend implements the same session contract without tmux tab
semantics. `vim-slime` and `nvim-slimetree` remain the execution/send layer.

Current module ownership is described in `lua/ark/README.md`; Rust bridge
boundaries are described in
`crates/ark-lsp-core/src/lsp/session_bridge/README.md`. `SPEC.md` is the complete
contract and near-term architectural direction.

Inherited Positron/Jupyter documents are isolated under `doc/upstream/` and are
not supported product documentation.
