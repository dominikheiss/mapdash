#!/bin/bash
# Reinstall previously SHA-1-verified staged maps. Warcraft need not be running.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$(command -v python3)" "$ROOT/Sources/Probe/V28Restore.py"
