# Ark.nvim product architecture

Ark has three active product layers:

1. `ark-lsp`, a detached Rust stdio host backed by `crates/ark-lsp-core`, which owns documents, static analysis, diagnostics, indexing, and protocol handling.
2. A versioned local IPC session bridge in `packages/arkbridge`, served from the managed R process, for runtime completions, hover, signatures, help, ArkView, explicit traceback inspection, and target cache facts.
3. The Neovim plugin, which owns configuration, backend lifecycle, LSP launch, status, health, support reporting, and editor UI.

The managed R session never lives inside the LSP. Tmux is the canonical backend: one active managed session is selected, and inactive Ark tabs are parked in hidden tmux windows. The built-in terminal backend implements the same session contract without tmux tab semantics. This is not a general simultaneous multi-pane orchestration layer. `vim-slime` and `nvim-slimetree` remain the source-buffer execution/send layer; Ark's console owns its own interactive input.

Native ArkHelp, ArkView, target actions, and traceback navigation are supported Neovim UI, not ports of Positron frontend protocols. Traceback inspection is explicit and bounded: live calls use the bridge, source jumps require genuine source references, and saved target tracebacks use a disposable R worker. No debugger, arbitrary-frame evaluator, or automatic error hook is implied.

Explicit target rebuild previews also use a disposable R worker rather than the managed session. The public targets APIs evaluate on-disk pipeline configuration, not target commands; configuration side effects still apply. Output, deadlines, and cancellation are bounded, and unsaved buffers are called out rather than silently written. Static frontmatter schemas, document-relative bibliography/CSL paths, and missing-file diagnostics remain in the Rust LSP and do not require live R or a general YAML server.

Readiness, activity, and failure are separate signals. A live prompt, an IPC response, submitted-code activity, and an in-flight Ark operation are not interchangeable. Status and support reports use bounded metadata-only evidence; neither a stale ready file nor a timeout alone proves R is ready, busy, or dead. Known busy evidence can suppress redundant bridge work while static language features remain available.

The shared Rust LSP crate has an `attached-runtime` compatibility feature for the retained upstream `ark` kernel host. Workspace dependencies disable it by default, `crates/ark` opts in explicitly, and the product `ark-lsp` does not. Consequently the released stdio server cannot construct attached mode and does not compile the kernel console, serialized attached-R task hooks, TCP host server, or attached UI callbacks.

Current Lua ownership is described in [the module guide](../lua/ark/README.md); Rust bridge boundaries are described in [the bridge guide](../crates/ark-lsp-core/src/lsp/session_bridge/README.md). [SPEC.md](../SPEC.md) is the complete contract and near-term architectural direction. The active LSP deliberately retains `Document` and the fork-owned indexer; upstream `OpenFile`/`OakDatabase` migration remains a separate decision documented in [the state-model note](../crates/ark-lsp-core/UPSTREAM_STATE_MODEL.md).

Inherited Positron/Jupyter documents are isolated under `doc/upstream/` and are not supported product documentation.
