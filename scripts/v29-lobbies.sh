#!/bin/bash
# Standalone or bundled backend for MapDash's local, read-only Warcraft lobby view.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
  printf '{"event":"state","status":"python3_missing"}\n'
  exit 2
fi
if [[ -x "$ROOT/bin/mapdash-guid-probe" ]]; then
  HELPER="$ROOT/bin/mapdash-guid-probe"
else
  HELPER="$(mktemp "${TMPDIR:-/tmp/}mapdash-guid.XXXXXX")"
  trap 'rm -f "$HELPER"' EXIT
  /usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$ROOT/Sources/Probe/V23GuidProbe.c" -o "$HELPER"
fi
"$PYTHON" -u "$ROOT/Sources/Probe/V29LobbyBridge.py" --guid-probe "$HELPER" "$@"
