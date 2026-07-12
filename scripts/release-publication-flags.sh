#!/usr/bin/env bash
set -euo pipefail

channel=${1:-}
case "${channel}" in
  alpha | beta)
    printf '%s\n' --prerelease --latest=false
    ;;
  stable)
    printf '%s\n' --latest
    ;;
  *)
    echo "unsupported release channel: ${channel:-<empty>}" >&2
    exit 2
    ;;
esac
