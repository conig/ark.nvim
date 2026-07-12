# Compatibility and upgrades

The planned first release channel is `alpha`; `v0.1.0-alpha.1` has not yet been
tagged or published. Alpha and beta GitHub releases are prereleases and are
never marked latest. Once published, normal users should pin the plugin to the
exact tag in `release-manifest.json`; `main` is the source-build/contributor
lane.

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
bridge runtime. To upgrade, change the plugin pin to the next published tag,
sync the plugin so its build hook installs the matching artifact, restart the
managed pane, then run `:Ark refresh`. Verify with `:checkhealth ark` and
`:Ark status`.

Rollback is whole-product rather than binary-only: pin and load the previous
plugin tag first. The normal build hook activates its matching artifact; without
that hook, run `:Ark rollback` from the previous plugin checkout. The command
refuses a previous LSP unless version, target, release profile, and bridge schema
all match. Restart the pane and refresh afterward.

Product CI blocks on both the minimum pair (Neovim 0.11.3 with R 4.2) and the
current stable Neovim/R pair. Neovim nightly with current R is a non-blocking
early-warning lane. The release workflow additionally clean-installs the exact
packaged binary and runs the required product tier before publication.
Installer upgrade, orphaned-lock recovery, failed-install preservation, and
safe rollback are exercised by release contract tests.
