#!/bin/bash
# V28 MapDash Rescue: one native Download Map click, then independent verified CDN download.
# Live Mac probe; requires Warcraft III open in Custom Games. Defaults to safe staging.
# Use --install to also place the finished map in Warcraft's Maps/Download without overwriting.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="$HOME/Library/Logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/MapDash-v28-rescue.log"
TMP="$(mktemp -d "${TMPDIR:-/tmp/}mapdash-v28.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
MODE="${1:-}"
if [[ -n "$MODE" && "$MODE" != '--install' ]]; then
  echo 'Usage: bash scripts/v28-rescue.sh [--install]' >&2; exit 2
fi
{
  echo "=== MapDash V28 rescue $(date '+%Y-%m-%d %H:%M:%S %z') ==="
  echo 'v28_experiment=first_working_rescue_download_after_native_trigger'
  echo 'v28_privacy=localhost_websocket; read_only_memory; no_credentials_in_log'
  echo 'v28_safety=one_modal_one_repeated_new_hash; sha1_check; stage_before_install; never_overwrite'
  PID="$(pgrep -x 'Warcraft III' | head -n 1 || true)"
  if [[ ! "$PID" =~ ^[0-9]+$ ]]; then echo 'v28_status=WARCRAFT_NOT_RUNNING'; exit 2; fi
  SOCKETS="$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN 2>/dev/null || true)"
  PORTS="$(printf '%s\n' "$SOCKETS" | awk 'NR>1{print $9}' | sed -nE 's/.*:([0-9]+)$/\1/p' | sort -nu | head -n 8 | paste -sd, -)"
  if [[ -z "$PORTS" ]]; then echo 'v28_status=NO_GAME_LISTENING_PORTS'; exit 2; fi
  echo "v28_game_ports=$PORTS"
  /usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$ROOT/Sources/Probe/V23GuidProbe.c" -o "$TMP/guid-probe"
  /usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$ROOT/Sources/Probe/V27CDNPathProbe.c" -o "$TMP/cdn-probe"
  PYTHON="$(command -v python3 || true)"
  if [[ -z "$PYTHON" ]]; then echo 'v28_status=PYTHON3_NOT_FOUND'; exit 2; fi
  ARGUMENTS=()
  if [[ "$MODE" == '--install' ]]; then ARGUMENTS+=(--install); fi
  # Session ID is NEVER saved to disk, emitted into argv, or printed to log.
  "$TMP/guid-probe" "$PID" | "$PYTHON" -u "$ROOT/Sources/Probe/V28Rescue.py" \
    --ports "$PORTS" --pid "$PID" --scanner "$TMP/cdn-probe" --seconds 90 "${ARGUMENTS[@]}"
} 2>&1 | tee "$LOG"
echo "V28 log: $LOG"
