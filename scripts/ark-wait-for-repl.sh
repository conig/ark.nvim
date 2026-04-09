#!/usr/bin/env sh
set -eu

TMUX_SOCKET=""
TMUX_PANE=""
STATUS_FILE=""
TIMEOUT_MS="${ARK_PROMPT_WATCH_TIMEOUT_MS:-10000}"
POLL_MS=50

while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket)
      TMUX_SOCKET="$2"
      shift 2
      ;;
    --pane)
      TMUX_PANE="$2"
      shift 2
      ;;
    --status-file)
      STATUS_FILE="$2"
      shift 2
      ;;
    --timeout-ms)
      TIMEOUT_MS="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$TMUX_SOCKET" ] || [ -z "$TMUX_PANE" ] || [ -z "$STATUS_FILE" ]; then
  exit 0
fi

strip_ansi() {
  perl -pe 's/\e\[[0-9;]*[A-Za-z]//g'
}

status_is_ready() {
  [ -f "$STATUS_FILE" ] || return 1
  grep -q '"status":"ready"' "$STATUS_FILE"
}

status_already_repl_ready() {
  [ -f "$STATUS_FILE" ] || return 1
  grep -Eq '"repl_ready":(true|1)' "$STATUS_FILE"
}

prompt_ready() {
  capture=$(tmux -S "$TMUX_SOCKET" capture-pane -p -t "$TMUX_PANE" 2>/dev/null || true)
  [ -n "$capture" ] || return 1

  last_line=$(
    printf '%s' "$capture" \
      | strip_ansi \
      | awk 'NF { line = $0 } END { print line }'
  )
  last_line=$(printf '%s' "$last_line" | tr -d '\r' | sed 's/[[:space:]]*$//')

  case "$last_line" in
    *">")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

mark_repl_ready() {
  [ -f "$STATUS_FILE" ] || return 1

  ts=$(date +%s)
  tmp=$(mktemp "${STATUS_FILE}.XXXXXX")

  perl -0pe '
    if (s/"repl_ready"\s*:\s*(?:false|0|true|1)/"repl_ready":true/) {
      $_ =~ s/"repl_ts"\s*:\s*\d+/"repl_ts":'"$ts"'/ or s/\}\s*$/,"repl_ts":'"$ts"'}/;
    } else {
      s/\}\s*$/,"repl_ready":true,"repl_ts":'"$ts"'}/;
    }
  ' "$STATUS_FILE" > "$tmp"

  chmod 600 "$tmp"
  mv "$tmp" "$STATUS_FILE"
}

deadline_ms=$(($(date +%s%3N) + TIMEOUT_MS))

while [ "$(date +%s%3N)" -lt "$deadline_ms" ]; do
  if status_already_repl_ready; then
    exit 0
  fi

  if status_is_ready && prompt_ready; then
    mark_repl_ready
    exit 0
  fi

  sleep 0.05
done

exit 0
