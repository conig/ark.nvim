# README Minimal Config

This directory contains an isolated Neovim config that mirrors the minimal
local-checkout setup recommended in the repo `README.md`.

Use it to validate that the documented plugin combination still works:

- `blink.cmp`
- `nvim-autopairs`
- `vim-slime`
- `nvim-slimetree`
- local checkout of `ark.nvim`

The config also includes the basic send mappings from the README:

- Normal `<CR>` sends the current R form
- Normal `<leader><CR>` sends the current R form and keeps the cursor in place
- Normal `<C-c><C-c>` sends the current line
- Visual `<CR>` sends the selected region

`nvim-slimetree` depends on Tree-sitter parsers for chunk/form sends. In
practice, that means `<CR>` and `<leader><CR>` need the relevant parser(s)
installed; at minimum, `.R` buffers need the `r` parser.

This harness intentionally configures `nvim-slimetree` to send through
`vim-slime` (`transport.backend = "slime"`), which matches the recommended
`ark.nvim` workflow for moving code from buffer to REPL.

Because this test harness isolates `XDG_DATA_HOME`, it also prepends the shared
`~/.local/share/nvim/site` runtime path and explicitly starts Tree-sitter for
R-family buffers so the send mappings behave like a normal user setup.

Primary entrypoints:

- `scripts/start-readme-test-nvim.sh`
- `scripts/smoke-readme-test-config.sh`
- `docker/readme-minimal/Dockerfile`
- `scripts/docker-readme-test.sh`

Docker usage from the repo root:

```sh
docker build -f docker/readme-minimal/Dockerfile -t ark-readme-test .
docker run --rm -it ark-readme-test
docker run --rm ark-readme-test smoke
```

The image packages this same config, prebuilds `ark-lsp`, installs the minimal
plugin set under `~/.local/share/nvim/lazy`, includes the Debian
`r-cran-tidyverse` bundle, and bakes in the Tree-sitter `r` and `markdown`
parsers that the isolated config expects. It currently pins Neovim `v0.12.1`,
matching the repo's supported baseline.

Generated runtime data stays under this directory:

- `testing/readme-minimal/data`
- `testing/readme-minimal/state`
- `testing/readme-minimal/cache`

On first run, `lazy.nvim` may still need to install any missing dependencies
that are not already present under `~/.local/share/nvim/lazy/`.
