#!/bin/bash
# Checks the built .app before it becomes an .ipa.
set -euo pipefail
APP="$1"
fail() { echo "CHECK FAILED: $1"; exit 1; }

[ -d "$APP" ] || fail "App not found at $APP"
[ -f "$APP/SecondMind" ] || fail "App binary missing"
lipo -info "$APP/SecondMind" | grep -q arm64 || fail "App is not built for iPhone (arm64)"

# Any framework the app loads at launch must be packed inside it, or it crashes on open.
for fw in $(otool -L "$APP/SecondMind" | awk '/@rpath\/.*\.framework/ {print $1}' | sed -E 's#@rpath/([^/]+)\.framework.*#\1#'); do
  [ -d "$APP/Frameworks/$fw.framework" ] || fail "$fw.framework is needed but not inside the app"
  echo "Found $fw.framework"
done

# No embedded entitlements: Sideloadly adds the right ones for a free Apple ID.
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q -e HotspotConfiguration -e wifi-info; then
  fail "Built app carries Hotspot or Wi-Fi Info entitlements"
fi

[ -z "$(plutil -extract MWDAT.MetaAppID raw -o - "$APP/Info.plist" 2>/dev/null || true)" ] || \
  echo "Note: MetaAppID is set; Developer Mode builds normally leave it empty."

echo "App OK"
