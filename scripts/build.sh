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
mkdir -p "$APP/Contents/MacOS" "$OUT/obj" \
    "$APP/Contents/Resources/MapDashBridge/Sources/Probe" \
    "$APP/Contents/Resources/MapDashBridge/scripts" \
    "$APP/Contents/Resources/MapDashBridge/bin"
# Package all rescue dependencies: the app must work independently of this source folder.
cp "$ROOT"/Sources/Probe/{V23GuidProbe.c,V23LocalSocketProbe.py,V27CDNPathProbe.c,V28Rescue.py,V28Restore.py,V29LobbyBridge.py,V30AutoRescue.py} \
    "$APP/Contents/Resources/MapDashBridge/Sources/Probe/"
cp "$ROOT"/scripts/{v28-rescue.sh,v28-restore.sh,v29-lobbies.sh,v30-auto-rescue.sh} \
    "$APP/Contents/Resources/MapDashBridge/scripts/"
# Compile a native GUID helper for the live-lobby feed; the V28 rescue helper
# builds its own two scanner binaries on the user's Mac, as it did in V28.
for arch in arm64 x86_64; do
  clang -O2 -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=$MIN \
    "$ROOT/Sources/Probe/V23GuidProbe.c" -o "$OUT/obj/mapdash-guid-$arch"
done
lipo -create "$OUT/obj/mapdash-guid-arm64" "$OUT/obj/mapdash-guid-x86_64" \
  -output "$APP/Contents/Resources/MapDashBridge/bin/mapdash-guid-probe"
chmod +x "$APP/Contents/Resources/MapDashBridge/bin/mapdash-guid-probe"
# V30 also bundles the precise, read-only CDN URL scanner. Avoid invoking
# clang each time Warcraft starts or its WebSocket reconnects.
for arch in arm64 x86_64; do
  clang -O2 -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=$MIN \
    "$ROOT/Sources/Probe/V27CDNPathProbe.c" -o "$OUT/obj/mapdash-cdn-$arch"
done
lipo -create "$OUT/obj/mapdash-cdn-arm64" "$OUT/obj/mapdash-cdn-x86_64" \
  -output "$APP/Contents/Resources/MapDashBridge/bin/mapdash-cdn-probe"
chmod +x "$APP/Contents/Resources/MapDashBridge/bin/mapdash-cdn-probe"

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

# No resource forks or extended attributes: they only add ._ files (com.apple.provenance).
(cd "$OUT" && ditto -c -k --norsrc --noextattr --keepParent MapDash.app "MapDash-$VERSION.zip")
rm -rf "$OUT/obj"
echo "$APP"
echo "$OUT/MapDash-$VERSION.zip"
