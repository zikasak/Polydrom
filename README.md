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
