#!/usr/bin/env sh
set -eu

R_BIN="${ARK_NVIM_R_BIN:-R}"
R_ARGS="${ARK_NVIM_R_ARGS:---quiet --no-save}"

export ARK_NVIM=1

exec "$R_BIN" $R_ARGS
