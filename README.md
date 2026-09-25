<p align="center">
  <img src="PolyDrom/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="128" height="128" alt="PolyDrom app icon">
</p>

<h1 align="center">PolyDrom</h1>

<p align="center">
  A fast, native Navidrome music player for macOS.
</p>

<p align="center">
  <a href="https://github.com/zikasak/Polydrom/releases/latest">Latest release</a>
  ·
  <a href="https://github.com/zikasak/Polydrom/issues">Report an issue</a>
  ·
  <a href="LICENSE">MIT license</a>
</p>

PolyDrom brings a full desktop listening experience to a self-hosted Navidrome library. It is built entirely with SwiftUI and AVFoundation, connects through the Subsonic API, and keeps each server's library available for browsing when the server is offline.

## Highlights

- **Native macOS experience** — a responsive SwiftUI interface with compact and expanded players, system Now Playing integration, keyboard-friendly controls, and AirPlay and Sonos output controls.
- **A library built for discovery** — featured, recently added, recently played, and random albums; quick mixes of 10, 25, or 50 tracks; song- and album-grouped full-library shuffle; and search across titles, artists, and albums.
- **Complete library navigation** — browse albums, artists, playlists, favorites, recent history, and detailed album or artist pages with cached artwork.
- **Real queue management** — play immediately, play next, append to the queue, jump between tracks, seek, change volume, and resume the current queue and position after relaunching.
- **Synced listening state** — report Now Playing and completed listens to Navidrome; star songs, albums, and artists; create, rename, update, and delete editable playlists; and display plain or time-synced lyrics.
- **Multi-server support** — save multiple accounts, switch from the sidebar, reconnect automatically to the most recently used server, and maintain isolated caches for every server and user.
- **Offline library browsing** — cached metadata, favorites, playlists, play history, and artwork remain available without a server connection. Streaming and server mutations still require connectivity.
- **Spotify discovery links** — open an artist or album search on Spotify directly from its page or context menu.
- **Built-in updates** — Sparkle checks the signed release feed and downloads new DMGs from GitHub Releases.

## Requirements

| | Requirement |
| --- | --- |
| Mac | Apple silicon (`arm64`) |
| macOS | 26.5 or later |
| Server | A reachable [Navidrome](https://www.navidrome.org/) server and user account |
| Developer build | Xcode 26.6 or later with Swift 6 |

PolyDrom uses Navidrome's Subsonic-compatible API. No additional server-side plugin is required.

## Install PolyDrom

1. Download [the latest PolyDrom DMG](https://github.com/zikasak/Polydrom/releases/latest/download/PolyDrom.dmg).
2. Open `PolyDrom.dmg` and drag **PolyDrom** into **Applications**.
3. Launch PolyDrom, then enter the full address of your Navidrome server, your username, and your password in the Settings window.

Release builds are currently distributed without an Apple Developer signature or notarization. On first launch, macOS may block the app. If it does, open **System Settings → Privacy & Security**, find the PolyDrom message, choose **Open Anyway**, and confirm the launch. Only install a DMG downloaded from this repository's Releases page; each release also includes a SHA-256 checksum.

### Connect for the first time

The Settings window opens automatically when there is no saved server.

- Enter an absolute server URL including `https://` or `http://`, for example `https://music.example.com`.
- HTTPS is strongly recommended whenever the server is reached outside a trusted local network.
- Select **Save & Connect**. PolyDrom stores the profile, validates the connection, downloads the library metadata, and opens the Home view.
- Add another account or server from **PolyDrom → Settings**. Use the server picker in the sidebar to switch later.

## Using the app

### Home and library

Home combines featured albums, recent additions, listening history, random albums, and one-click mixes. The sidebar provides dedicated views for search, random songs, albums, artists, playlists, favorites, and recent tracks.

Most songs, albums, and artists expose the same actions from their context menus:

- Play, play next, or add to the end of the queue.
- Add to or remove from favorites.
- Add songs to an editable playlist or create a new playlist from the selection.
- Open the related album or artist.
- Search for an album or artist on Spotify.

### Playback

The compact player stays available while browsing. Open it to see the expanded Now Playing experience with large artwork, elapsed time, seeking, volume, favorite and stop controls, AirPlay, Sonos output, the current queue, and lyrics.

Choose a Sonos room from the speaker menu in either player. PolyDrom uses the room's existing Sonos group, copies its queue to the group, and then sends the group a Navidrome MP3 URL for each song. The Sonos speakers must be on a network where they can reach the configured Navidrome address directly; `localhost`, Mac-only VPN addresses, and inaccessible HTTPS certificates will not work. Sonos app and hardware next/previous controls follow the copied queue. PolyDrom remains the source of queue edits; if another app changes the Sonos queue or source, select the group again to copy PolyDrom's queue. Large queues continue copying while the first tracks play, so only copied tracks are available in the Sonos app during that time. Switching back to Mac/AirPlay or quitting PolyDrom stops Sonos and clears PolyDrom's copied queue from the group.

PolyDrom publishes track metadata and artwork to macOS Now Playing and supports the system play, pause, stop, previous, next, and seek commands. The queue, selected track, playback position, and Mac/AirPlay volume are persisted locally so an interrupted session can be resumed after relaunch. Sonos group volume stays separate, and Sonos output is not restored automatically.

While connected, PolyDrom also reports the current track to Navidrome so its **Now Playing** view identifies PolyDrom, the song, and—on servers supporting [OpenSubsonic playback reporting](https://opensubsonic.netlify.app/docs/endpoints/reportplayback/)—the current play, pause, and position state. Older servers receive compatible [Subsonic scrobble](https://opensubsonic.netlify.app/docs/endpoints/scrobble/) now-playing notifications instead. Qualifying listens are recorded in Navidrome's history and play counts and can be forwarded to scrobbling services configured there. On a normal app quit, PolyDrom briefly waits for its final server update without clearing the locally saved queue or playback position.

Navidrome must have **Enable Now Playing** enabled, and scrobbling must be enabled for the PolyDrom player. Both are enabled by default. A legacy server cannot clear or pause a now-playing notification immediately, so that entry may remain visible until it expires.

### Playlists and favorites

Favorites are synchronized with Navidrome for songs, albums, and artists. Playlist changes are written back to the server. Read-only playlists can be played and browsed but cannot be renamed, edited, or deleted.

### Metadata and offline behavior

PolyDrom keeps a disposable, server-scoped metadata cache. The first successful connection performs a full catalog synchronization. Later checks compare the server's catalog state and refresh only user metadata when the catalog has not changed. If Navidrome is scanning, PolyDrom defers the refresh and retries after the scan.

Automatic checks run only while the app is active. Choose **Manually**, **Every 5 minutes**, **Every 15 minutes**, **Every 30 minutes**, or **Every hour** in Settings; 15 minutes is the default. The refresh button in the library toolbar always starts a manual check.

When a server cannot be reached, PolyDrom loads its cached library automatically. Offline mode supports browsing and searching cached content and history, but not audio streaming, favorites changes, or playlist mutations. PolyDrom does not download audio for offline playback.

## Data and security

- Passwords are stored in the macOS Keychain and are not written to the library database or server registry.
- Non-secret server profiles are stored atomically in Application Support.
- Catalog metadata, favorites, playlists, and local playback history are stored in a server-scoped Core Data cache.
- Cover art is cached separately on disk and in memory.
- Deleting a saved server removes its Keychain credential and cached library from the Mac.
- Clearing **Library metadata** removes all cached libraries and local play history but preserves saved servers and passwords.
- Clearing **Cover art** removes downloaded and decoded images; they are fetched again on demand.
- Network logs record request method, status, latency, and response size, but not passwords or authentication query values.
- Sonos receives authenticated Navidrome stream and artwork URLs while it plays. PolyDrom does not save those URLs, and clears its copied Sonos queue when you switch away or quit.

Plain HTTP is supported for local Navidrome installations, so transport security ultimately depends on the URL you configure. Prefer HTTPS for any connection that crosses an untrusted network.

## Build from source

Clone the repository and open the shared Xcode scheme:

```sh
git clone https://github.com/zikasak/Polydrom.git
cd Polydrom
open PolyDrom.xcodeproj
```

Or build from Terminal without code signing:

```sh
xcodebuild build \
  -project PolyDrom.xcodeproj \
  -scheme PolyDrom \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

Xcode resolves the only application dependency, [Sparkle 2](https://github.com/sparkle-project/Sparkle), through Swift Package Manager.

## Test and quality checks

Run the complete Xcode test plan:

```sh
bash scripts/test.sh
```

This includes the unit, persistence, networking, playback, rendering, and UI test targets. UI tests require a logged-in macOS session with permission to run the test host.

Install the repository's static-analysis tools and run the full quality gate:

```sh
brew bundle
bash scripts/quality.sh
```

The quality gate:

1. Builds the project and tests with Swift 6 complete concurrency checking and warnings as errors.
2. Runs the `PolyDromTests` unit and rendering suite.
3. Runs SwiftLint in strict mode.
4. Scans production and test code separately with Periphery so test-only references cannot hide unused production APIs.

SwiftLint and Periphery intentionally run outside Xcode build phases to keep normal app builds deterministic and fast.

## Architecture

PolyDrom keeps application coordination at the boundary and gives networking, storage, synchronization, artwork, and playback narrow responsibilities:

```text
SwiftUI views
    │
    ▼
AppCoordinator ─────────────── AudioPlayer / Now Playing / AirPlay
    │
    ├── NavidromeClient ────── Subsonic API, streams, lyrics, artwork
    ├── LibrarySyncCoordinator
    ├── ServerRegistry ─────── Application Support + Keychain
    ├── LibraryStore ───────── server-scoped Core Data cache
    ├── PlaybackPersistence ── queue, position, and volume
    └── CoverArtCache ──────── bounded memory and disk caches
```

- `AppCoordinator` uses a session generation to prevent a canceled connection, deleted server, or stale asynchronous response from changing the active library or player.
- `LibrarySyncCoordinator` performs paged catalog synchronization, coalesces concurrent refreshes, retries a catalog that changes mid-sync, and applies updates atomically.
- `LibraryStore` is disposable by design. If its cache cannot be migrated or opened, only the affected local cache is rebuilt; saved server profiles and Keychain credentials remain intact.
- UI and AVFoundation state stay on the main actor. Transport and domain values are `Sendable`, while Core Data work runs on background contexts.
- `CoverArtCache` deduplicates in-flight downloads, bounds network and decode concurrency, and prevents an old request from repopulating a cache after it has been cleared.

### Repository layout

```text
PolyDrom/
├── Models/          Domain and metadata models
├── Persistence/     Core Data, server registry, Keychain, playback state
├── Playback/        AVPlayer, Now Playing, and AirPlay integration
├── Services/        Navidrome API, synchronization, updates, cover art
├── ViewModels/      Application and playlist coordination
└── Views/           SwiftUI library, settings, and player views
PolyDromTests/       Unit, integration, persistence, and rendering tests
PolyDromUITests/     End-to-end macOS UI tests
Config/              Info.plist and sandbox entitlements
scripts/             Test, quality, and release helpers
```

## Diagnostics

PolyDrom uses Apple unified logging. Stream all app logs from Terminal:

```sh
log stream --style compact --predicate 'subsystem == "uk.zikasak.PolyDrom"'
```

Useful categories include `app`, `network`, `persistence`, `sync`, and `playback`.

If the app behaves unexpectedly:

- **Cannot connect:** verify that the address includes its scheme, is reachable from the Mac, and accepts the supplied Navidrome credentials.
- **Library looks out of date:** wait for any Navidrome scan to finish, then select **Refresh Library**.
- **Artwork is stale or missing:** clear **Cover art** in Settings and revisit the item while online.
- **Cached library is inconsistent:** clear **Library metadata**, reconnect, and let PolyDrom rebuild it. Saved server credentials are preserved.
- **A release will not open:** use **Open Anyway** in Privacy & Security after confirming that the DMG came from this repository.

When reporting a bug, include the macOS version, PolyDrom version, Navidrome version, reproduction steps, and relevant redacted logs. Never post credentials or complete authenticated request URLs.

## Releases and updates

GitHub Actions builds and tests every pull request and push to `main`, then produces an unsigned Apple-silicon DMG. After a successful `main` build, [semantic-release](https://github.com/semantic-release/semantic-release) analyzes Conventional Commits since the previous release and, when one is required, publishes:

- `PolyDrom.dmg`
- `PolyDrom.dmg.sha256`
- `appcast.xml`

Sparkle verifies update archives with Ed25519 before offering them to the user. Automatic checks are enabled, but installation remains user initiated. The app also provides **Check for Updates…** in its application menu.

### Maintainer release setup

Before the first release, generate the Sparkle key with the tools resolved by Xcode. Keep the exported private key out of the repository:

```sh
generate_keys --account uk.zikasak.PolyDrom
generate_keys --account uk.zikasak.PolyDrom \
  -x /private/tmp/polydrom-sparkle-private-key
gh secret set SPARKLE_ED_PRIVATE_KEY \
  < /private/tmp/polydrom-sparkle-private-key
rm /private/tmp/polydrom-sparkle-private-key
```

The public key belongs in `Config/Info.plist`; the private key is used only by the release workflow. Releases are determined automatically from commits merged into `main`:

- `fix:` and `perf:` create a patch release.
- `feat:` creates a minor release.
- A `BREAKING CHANGE:` footer or `!` after the type creates a major release.
- Other commit types do not create a release by default.

Use Conventional Commit messages for commits that reach `main`, including squash-merge titles, for example `fix(playback): resume after reconnect`. semantic-release calculates the next version, creates the `vMAJOR.MINOR.PATCH` tag and release notes, stamps the archived app with that version, and uploads the DMG, checksum, and appcast to the GitHub release. The Xcode project's marketing version remains the fallback for local, pull-request, and manual workflow builds; it does not need to be changed for releases. Manual workflow runs build artifacts but never publishes a GitHub release.

The release workflow intentionally does not perform Apple Developer signing, notarization, or stapling. Adding those steps requires an Apple Developer identity and corresponding GitHub secrets.

## Contributing

Issues and focused pull requests are welcome. Before opening a PR:

1. Keep changes scoped and preserve server isolation, Keychain handling, and session-generation guards.
2. Add or update tests for behavior changes.
3. Run `bash scripts/quality.sh` and resolve every warning.
4. Do not commit credentials, private Sparkle keys, derived data, build products, or local library caches.

Use [GitHub Issues](https://github.com/zikasak/Polydrom/issues) for bugs and feature proposals.

## License and third-party marks

Original source code and project files are available under the [MIT License](LICENSE).

Third-party names, trademarks, and assets—including Navidrome and Spotify marks—are not granted by the MIT License. The app icon assets also require separate provenance confirmation before redistribution. See [NOTICE](NOTICE) for the complete attribution and asset notice.
