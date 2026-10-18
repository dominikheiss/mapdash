#!/bin/bash
# Continuously watch native Warcraft III Download Map clicks while MapDash runs.
# Maps are fetched only after a unique, stable Blizzard CDN SHA-1 is detected.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
  echo '{"event":"state","status":"python3_missing"}'
  exit 2
fi
if [[ -x "$ROOT/bin/mapdash-guid-probe" && -x "$ROOT/bin/mapdash-cdn-probe" ]]; then
  GUID="$ROOT/bin/mapdash-guid-probe"
  CDN="$ROOT/bin/mapdash-cdn-probe"
else
  TMP="$(mktemp -d "${TMPDIR:-/tmp/}mapdash-v30.XXXXXX")"
  trap 'rm -rf "$TMP"' EXIT
  /usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$ROOT/Sources/Probe/V23GuidProbe.c" -o "$TMP/guid"
  /usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$ROOT/Sources/Probe/V27CDNPathProbe.c" -o "$TMP/cdn"
  GUID="$TMP/guid"; CDN="$TMP/cdn"
fi
"$PYTHON" -u "$ROOT/Sources/Probe/V30AutoRescue.py" \
  --guid-probe "$GUID" --cdn-probe "$CDN" "$@"
