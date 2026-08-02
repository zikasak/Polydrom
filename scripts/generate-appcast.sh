#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 APP_PATH DMG_PATH SIGN_UPDATE_PATH OUTPUT_PATH" >&2
  exit 2
fi

app_path="$1"
dmg_path="$2"
sign_update_path="$3"
output_path="$4"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${RELEASE_TAG:?RELEASE_TAG is required}"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required}"

info_plist="$app_path/Contents/Info.plist"
test -f "$info_plist"
test -f "$dmg_path"
test -x "$sign_update_path"

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
minimum_system_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")"
test -n "$bundle_version"
test -n "$short_version"
test -n "$minimum_system_version"

signature="$(
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
    "$sign_update_path" --ed-key-file - -p "$dmg_path"
)"
test -n "$signature"

archive_length="$(stat -f '%z' "$dmg_path")"
pub_date="$(date -u '+%a, %d %b %Y %H:%M:%S %z')"
download_url="https://github.com/${GITHUB_REPOSITORY}/releases/download/${RELEASE_TAG}/PolyDrom.dmg"
feed_url="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download/appcast.xml"

{
  printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
  printf '%s\n' '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  printf '%s\n' '  <channel>'
  printf '    <title>PolyDrom Updates</title>\n'
  printf '    <link>%s</link>\n' "$feed_url"
  printf '%s\n' '    <description>PolyDrom software updates</description>'
  printf '%s\n' '    <item>'
  printf '      <title>PolyDrom %s</title>\n' "$short_version"
  printf '      <sparkle:version>%s</sparkle:version>\n' "$bundle_version"
  printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$short_version"
  printf '      <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$minimum_system_version"
  printf '      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n'
  printf '      <pubDate>%s</pubDate>\n' "$pub_date"
  printf '      <enclosure url="%s" sparkle:edSignature="%s" length="%s" type="application/octet-stream" />\n' \
    "$download_url" "$signature" "$archive_length"
  printf '%s\n' '    </item>'
  printf '%s\n' '  </channel>'
  printf '%s\n' '</rss>'
} > "$output_path"
