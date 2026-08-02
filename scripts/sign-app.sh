#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 APP_PATH [ENTITLEMENTS_PATH]" >&2
  exit 2
fi

app_path="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
entitlements_path="${2:-$script_dir/../Config/PolyDrom.entitlements}"

test -d "$app_path"
test -f "$app_path/Contents/Info.plist"
test -f "$entitlements_path"

sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_version="$sparkle_framework/Versions/B"
test -d "$sparkle_framework"
test -d "$sparkle_version"

# An ad-hoc identity is available without an Apple Developer Program account.
# It makes the bundle's code and resources internally verifiable, but it does
# not identify the developer to Gatekeeper or replace notarization.
signing_identity="-"

# Sparkle contains nested executables and services. Sign the deepest items
# first, then the framework, and finally the containing application. Do not
# replace this with codesign --deep: Sparkle's sandboxed helpers have different
# entitlements and need to be signed individually.
codesign --force --sign "$signing_identity" --options runtime \
  "$sparkle_version/XPCServices/Installer.xpc"
codesign --force --sign "$signing_identity" --options runtime \
  --preserve-metadata=entitlements \
  "$sparkle_version/XPCServices/Downloader.xpc"
codesign --force --sign "$signing_identity" --options runtime \
  "$sparkle_version/Autoupdate"
codesign --force --sign "$signing_identity" --options runtime \
  "$sparkle_version/Updater.app"
codesign --force --sign "$signing_identity" --options runtime \
  "$sparkle_framework"

# Leave the application without the hardened runtime. An ad-hoc application
# cannot use the same library-validation setup as a Developer ID build, while
# Sparkle's nested helpers retain the runtime configuration they ship with.
codesign --force --sign "$signing_identity" \
  --entitlements "$entitlements_path" \
  "$app_path"

codesign --verify --deep --strict --verbose=2 "$app_path"
