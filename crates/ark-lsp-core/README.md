This directory is the shared source-of-truth for the LSP implementation that is
currently compiled in both `crates/ark` and `crates/ark-lsp`.

Why it exists:
- most of the `lsp/` tree was byte-identical across the two crates
- the remaining divergence is concentrated in the host adapter files:
  `backend.rs`, `main_loop.rs`, and `state_handlers.rs`

Why it is not a standalone Cargo package yet:
- the shared code still relies on crate-root hooks such as `console`, `r_task`,
  `analysis`, `fixtures`, and `url`
- those hooks still differ enough between the attached `ark` runtime and the
  detached `ark-lsp` runtime that forcing a full crate boundary now would add
  more abstraction churn than clarity

The intended next step is to keep shrinking those host hooks until this source
tree can become a real shared library crate rather than a path-shared module
tree.
