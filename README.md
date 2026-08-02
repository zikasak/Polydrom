# PolyDrom

PolyDrom is a native macOS client for Navidrome. The UI keeps its feature-oriented
state at the application boundary: `AppCoordinator` owns the active session, while
server registry, library cache, synchronization, and playback have narrow,
independently testable responsibilities.

## License

Original source code and project files are licensed under the [MIT License](LICENSE).
Third-party names, trademarks, and assets are excluded from that license; see
[NOTICE](NOTICE) for details.

## Architecture

- `ServerRegistry` atomically stores non-secret server metadata in Application
  Support. Passwords are stored only through `CredentialStoring` (Keychain in the
  app). It imports identifiers and credential associations from the legacy store
  once.
- `LibraryStore` is a disposable, server-scoped Core Data cache for catalog data,
  favorites, and local playback history. A failed migration or open removes only
  that cache and retries; saved servers and Keychain entries are unaffected.
- `LibrarySyncCoordinator` reconciles Navidrome metadata with the cache.
- `AppCoordinator` guards asynchronous work with a session generation so a
  canceled connection, deleted server, or stale response cannot alter the active
  library or player state.
- UI and AVFoundation state are isolated to the main actor. Domain and transport
  values are `Sendable`; cache work uses Core Data background contexts.

## Requirements

Xcode with Swift 6 is required. Install the repository tooling once:

```sh
brew bundle
```

## Releases and updates

Release builds use Sparkle 2 to check for updates from the appcast published as
the `appcast.xml` asset of the latest GitHub release. Sparkle downloads the DMG
directly from the release asset; it does not open the GitHub release page. The
workflow uses Sparkle's `sign_update` tool because `generate_appcast` requires
Apple-signed application bundles, which are unavailable for this unsigned build.

Before creating the first release, generate an Ed25519 key with the Sparkle
tools resolved by Xcode. Keep the private key out of the repository:

```sh
generate_keys --account uk.zikasak.PolyDrom
generate_keys --account uk.zikasak.PolyDrom -x /private/tmp/polydrom-sparkle-private-key
gh secret set SPARKLE_ED_PRIVATE_KEY < /private/tmp/polydrom-sparkle-private-key
rm /private/tmp/polydrom-sparkle-private-key
```

The public key is stored in `Config/Info.plist`; the private key is used only by
GitHub Actions when generating signed appcasts. A `v*` tag push creates a
release automatically. A manual workflow dispatch can also create a release
with `create_release` enabled.

The release workflow intentionally skips Apple Developer signing, notarization,
and stapling. The distributed DMG is therefore unsigned; macOS may require the
user to approve the first launch through Gatekeeper or Privacy & Security.

## Build and test

```sh
xcodebuild build -project PolyDrom.xcodeproj -scheme PolyDrom \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO

bash scripts/test.sh
```

The UI tests need an unsandboxed macOS test runner. The unit and rendering suite
can run through the command above when the local test service is available.

## Quality gate

```sh
bash scripts/quality.sh
```

The quality gate compiles with Swift 6, complete concurrency checking, and
warnings-as-errors; then runs the unit suite, SwiftLint in strict mode, and two
Periphery scans. The production scan is deliberately independent of tests so a
test-only use cannot hide a dead production API. Do not add these tools to Xcode
build phases.

## Viewing logs

PolyDrom uses Apple unified logging. Stream its logs from Terminal with:

```sh
log stream --style compact --predicate 'subsystem == "uk.zikasak.PolyDrom"'
```

The `network` category records request methods, status, latency, and response
size without recording authentication parameters or passwords.
