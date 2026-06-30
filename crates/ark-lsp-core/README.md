`ark-lsp-core` is the shared source of truth for the Neovim-facing LSP
implementation used by both host crates:

- `crates/ark`: attached legacy kernel host
- `crates/ark-lsp`: detached stdio host for `ark.nvim`

The shared crate owns the LSP module tree, indexing, diagnostics, completion,
hover, signature help, static state, bridge-aware handlers, and common
tree-sitter helpers. Host crates should not reintroduce `#[path]` imports into
this tree.

The attached `ark` host still owns the Amalthea `ServerHandler` wrapper and the
real R-thread scheduler. Those host-specific capabilities are installed into
this crate through the narrow hooks in `runtime.rs`:

- run a closure on the attached R thread
- read attached console state such as the selected environment and console
  inputs
- attach or remove the LSP event channel from the console
- surface crash messages through the attached UI comm when available

Detached `ark-lsp` uses the crate defaults, which deliberately avoid assuming an
embedded R runtime. Runtime-aware detached features should continue to flow
through `lsp/session_bridge.rs`.
