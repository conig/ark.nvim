# Compatibility and upgrades

| Component | Supported contract |
|---|---|
| Neovim | 0.11.3 or newer |
| R | 4.2.0 or newer |
| Published platform | Linux x86_64, glibc 2.35+ |
| Canonical backend | tmux |
| Additional backend | built-in Neovim terminal |
| Plugin API | 1 |
| LSP API | 1 |
| Bridge schema | v1 |

Ark uses exact product-version compatibility for the plugin, installed LSP, and
bridge runtime. Upgrade with `:Ark install`, restart the managed pane, then run
`:Ark refresh`. Verify with `:checkhealth ark` and `:Ark status`.

Rollback is atomic: `:Ark rollback` activates the previously installed release.
Restart the pane and refresh afterward so every component uses the same version.
Installer upgrade, failed-install preservation, and rollback are exercised by
the release-artifact product tests.
