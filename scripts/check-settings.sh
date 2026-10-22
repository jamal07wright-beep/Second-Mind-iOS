#!/bin/bash
# Fails the build if a setting would break a free Apple ID install.
set -euo pipefail
fail() { echo "CHECK FAILED: $1"; exit 1; }

PLIST=SecondMind/Info.plist
plutil -lint "$PLIST"

# Entitlements free accounts can't use.
if grep -rq --include="*.entitlements" -e "HotspotConfiguration" -e "wifi-info" . ; then
  fail "Hotspot or Wi-Fi Info entitlement found. Free Apple IDs can't use these."
fi
if grep -q "CODE_SIGN_ENTITLEMENTS: \"[^\"]" project.yml; then
  fail "project.yml points at an entitlements file. Keep it empty for Sideloadly."
fi

# Keys the glasses SDK needs.
for key in MWDAT CFBundleURLTypes UIBackgroundModes UISupportedExternalAccessoryProtocols \
           NSBluetoothAlwaysUsageDescription NSLocalNetworkUsageDescription NSBonjourServices; do
  plutil -extract "$key" raw -o /dev/null "$PLIST" 2>/dev/null || \
    plutil -extract "$key" xml1 -o /dev/null "$PLIST" || fail "Info.plist is missing $key"
done

SCHEME=$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$PLIST")
LINK=$(plutil -extract MWDAT.AppLinkURLScheme raw -o - "$PLIST")
[ "$LINK" = "${SCHEME}://" ] || fail "AppLinkURLScheme ($LINK) must match URL scheme ($SCHEME://)"

for mode in bluetooth-central bluetooth-peripheral external-accessory; do
  plutil -extract UIBackgroundModes xml1 -o - "$PLIST" | grep -q "$mode" || fail "Missing background mode $mode"
done

echo "Settings OK"
