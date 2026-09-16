#!/bin/bash
# Builds build/MapDash.app (universal) and build/MapDash-<version>.zip.
# Needs only the Command Line Tools (xcode-select --install); Xcode is not required.
#   scripts/build.sh            version from the VERSION file
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
OUT="$ROOT/build"
APP="$OUT/MapDash.app"
MIN=13.0

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$OUT/obj"

for arch in arm64 x86_64; do
  clang -O2 -Wall -Wextra -arch "$arch" -mmacosx-version-min=$MIN \
    -c "$ROOT/Sources/Scanner/scanner.c" -o "$OUT/obj/scanner-$arch.o"
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos$MIN" \
    -import-objc-header "$ROOT/Sources/Scanner/scanner.h" \
    "$ROOT"/Sources/App/*.swift "$OUT/obj/scanner-$arch.o" \
    -o "$OUT/obj/MapDash-$arch"
done
lipo -create "$OUT/obj/MapDash-arm64" "$OUT/obj/MapDash-x86_64" -output "$APP/Contents/MacOS/MapDash"

sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature: Apple Silicon refuses unsigned code. Without a Developer ID the app is not
# notarized, so users confirm it once under System Settings > Privacy & Security.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

(cd "$OUT" && ditto -c -k --keepParent MapDash.app "MapDash-$VERSION.zip")
rm -rf "$OUT/obj"
echo "$APP"
echo "$OUT/MapDash-$VERSION.zip"
