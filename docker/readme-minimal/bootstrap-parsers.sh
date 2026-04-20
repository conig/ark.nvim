#!/usr/bin/env bash
set -euo pipefail

site_root="${HOME}/.local/share/nvim/site"
plugin_root="${site_root}/pack/vendor/start/nvim-treesitter"

mkdir -p "${site_root}/pack/vendor/start"

if [[ ! -d "${plugin_root}/.git" ]]; then
  rm -rf "${plugin_root}"
  git clone --depth 1 --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter "${plugin_root}"
fi

exec nvim --headless -u NONE \
  -c "set runtimepath^=${plugin_root}" \
  -c "lua local ts = require('nvim-treesitter'); ts.setup({ install_dir = vim.fn.expand('~/.local/share/nvim/site') }); ts.install({ 'r', 'markdown' }):wait(300000); for _, lang in ipairs({ 'r', 'markdown' }) do local ok, err = pcall(vim.treesitter.language.add, lang); if not ok then error(string.format('failed to load %s parser after bootstrap: %s', lang, err)) end end" \
  -c "qa"
