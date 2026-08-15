#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 VERSION RELEASE_TAG" >&2
  exit 2
fi

version="$1"
release_tag="$2"
stable_semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

if [[ ! "$version" =~ $stable_semver ]]; then
  echo "Release version '$version' must match MAJOR.MINOR.PATCH without leading zeros." >&2
  exit 1
fi

if [[ "$release_tag" != "v$version" ]]; then
  echo "Release tag '$release_tag' does not match version '$version'." >&2
  exit 1
fi

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_NUMBER:?GITHUB_RUN_NUMBER is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required}"

archive_path="$RUNNER_TEMP/PolyDrom.xcarchive"
derived_data_path="$RUNNER_TEMP/PolyDrom-ReleaseData"
spm_path="$RUNNER_TEMP/PolyDrom-SourcePackages"
artifacts_path="release-assets"

xcodebuild -resolvePackageDependencies \
  -project PolyDrom.xcodeproj \
  -scheme PolyDrom \
  -clonedSourcePackagesDirPath "$spm_path"

xcodebuild archive \
  -project PolyDrom.xcodeproj \
  -scheme PolyDrom \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$spm_path" \
  ARCHS=arm64 \
  CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
  MARKETING_VERSION="$version" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO

app_path="$archive_path/Products/Applications/PolyDrom.app"
info_plist="$app_path/Contents/Info.plist"
test -f "$info_plist"

marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"

if [[ "$marketing_version" != "$version" ]]; then
  echo "Expected marketing version '$version', found '$marketing_version'." >&2
  exit 1
fi

if [[ "$bundle_version" != "$GITHUB_RUN_NUMBER" ]]; then
  echo "Expected bundle version '$GITHUB_RUN_NUMBER', found '$bundle_version'." >&2
  exit 1
fi

bash scripts/sign-app.sh "$app_path"

staging_path="$(mktemp -d "$RUNNER_TEMP/PolyDrom-dmg.XXXXXX")"
ditto "$app_path" "$staging_path/PolyDrom.app"
ln -s /Applications "$staging_path/Applications"

mkdir -p "$artifacts_path"
hdiutil create \
  -volname "PolyDrom" \
  -srcfolder "$staging_path" \
  -ov \
  -format UDZO \
  "$artifacts_path/PolyDrom.dmg"
hdiutil verify "$artifacts_path/PolyDrom.dmg"
(cd "$artifacts_path" && shasum -a 256 PolyDrom.dmg > PolyDrom.dmg.sha256)

sign_update="$(find "$spm_path" -type f -path '*/Sparkle/bin/sign_update' -print -quit)"
test -x "$sign_update"

# Sparkle's generate_appcast requires an Apple-issued distribution signature.
# This build uses an ad-hoc signature, so the helper signs the update metadata.
RELEASE_TAG="$release_tag" \
  bash scripts/generate-appcast.sh \
    "$app_path" \
    "$artifacts_path/PolyDrom.dmg" \
    "$sign_update" \
    "$artifacts_path/appcast.xml"

xmllint --noout "$artifacts_path/appcast.xml"
grep -Eq 'sparkle:edSignature="[^"]+"' "$artifacts_path/appcast.xml"
grep -Fq "<sparkle:shortVersionString>${version}</sparkle:shortVersionString>" "$artifacts_path/appcast.xml"
grep -Fq "https://github.com/${GITHUB_REPOSITORY}/releases/download/${release_tag}/PolyDrom.dmg" "$artifacts_path/appcast.xml"
if grep -Fq "/releases/tag/" "$artifacts_path/appcast.xml"; then
  echo "Sparkle appcast contains a release page URL instead of a download URL." >&2
  exit 1
fi

feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist")"
test "$feed_url" = "https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml"
