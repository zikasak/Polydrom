#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${TMPDIR:-/tmp}/PolyDrom-QualityData"
cd "$repo_root"

for tool in swiftlint periphery; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing $tool. Install tooling with: brew bundle" >&2
    exit 1
  fi
done

xcodebuild build-for-testing \
  -project PolyDrom.xcodeproj \
  -scheme PolyDrom \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test-without-building \
  -project PolyDrom.xcodeproj \
  -scheme PolyDrom \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  -only-testing:PolyDromTests \
  CODE_SIGNING_ALLOWED=NO

swiftlint lint --strict --no-cache --config .swiftlint.yml

# Production is scanned alone so tests cannot retain dead app APIs.
periphery scan --config .periphery.yml --exclude-tests

# Test support is audited separately from production references.
periphery scan --config .periphery.yml --report-include 'PolyDromTests/**/*.swift'
