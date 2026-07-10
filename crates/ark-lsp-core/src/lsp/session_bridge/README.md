# Session bridge boundaries

The detached LSP talks to the interactive R session through four explicit
layers:

- `session_bridge_runtime.rs` owns bounded admission, cancellation checks,
  end-to-end deadlines, circuit state, and raw TCP exchange.
- `session_bridge/protocol.rs` owns serialized request and response payloads.
- `session_bridge/completion.rs` owns completion-context planning and generation
  of the R expressions used to inspect completion contexts.
- `session_bridge.rs` is the feature client facade. It selects the trusted
  connection, applies one refresh retry after identity rotation, interprets
  feature responses, and exposes completion, hover, signature, help, ArkView,
  package, and `{targets}` operations to LSP handlers.

Only the runtime may enter the loopback transport, and it admits one request at
a time with a bounded waiting queue. Planning code must remain independent of
socket I/O. Protocol structures should contain wire representation only; they
must not decide fallback, retry, or completion precedence.
