#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${TMPDIR:-/tmp}/PolyDrom-TestData"
cd "$repo_root"

xcodebuild test \
  -project PolyDrom.xcodeproj \
  -scheme PolyDrom \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

