# Troubleshooting Ark.nvim

Start with `:Ark status`, then run `:checkhealth ark`. Both are safe in degraded
or static-only mode; health checks do not start R. If you need to share evidence,
run `:Ark report` and review the redacted preview before copying it.

| State | What still works | Recovery |
|---|---|---|
| `live_ready` | Static and live features | None |
| `static_starting` | Static LSP features | Wait for R/bridge hydration |
| `static_only` | Static LSP features | Enable/start a backend if live features are wanted |
| `live_degraded` | Static LSP features | `:Ark pane restart`, then `:Ark refresh` |
| `update_in_progress` | Existing static features | Wait for installation to finish |
| `restart_required` | Static LSP features | `:Ark install`, restart the pane, refresh |
| `unsupported` | No supported guarantee | Fix `:checkhealth ark` errors |

Common failures:

- Missing LSP: run `:Ark install`, then `:Ark refresh`.
- Missing `jsonlite`: run `install.packages("jsonlite")` in R.
- Tmux unavailable: run Neovim inside tmux or choose the terminal backend.
- Stale bridge/auth/version: install, restart the pane, then refresh.
- Read-only state/install location: fix ownership or set `ARK_STATUS_DIR` /
  `ARK_NVIM_INSTALL_ROOT` before Neovim starts.

For rollback, first pin and load the previous plugin release. Its build hook
normally selects the matching LSP; otherwise run `:Ark rollback` from that
checkout. Ark deliberately refuses binary-only cross-version rollback. Restart
the pane and refresh after every upgrade or rollback.

Ark error codes are stable support categories. `E_CONFIG` names invalid setup
paths; `E_BRIDGE_*` and `E_IPC_*` identify the live boundary; `E_EVAL` means the
requested R object/expression was unavailable. User-visible errors include a
recovery action, while the exact state remains in `:Ark status`.

Support reports never intentionally include buffer contents, R values,
arbitrary environment values, authentication tokens, cookies, or unrelated
system logs. They normalize user-specific paths and reference logs by location.
