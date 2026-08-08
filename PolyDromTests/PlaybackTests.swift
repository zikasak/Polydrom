import AVFoundation
import CoreGraphics
import Foundation
import MediaPlayer
import Testing
@testable import PolyDrom

@Suite(.serialized)
@MainActor
struct PlaybackTests {
    @Test func audioPlayerGuardsEmptyStateAndClampsVolume() {
        let player = AudioPlayer()
        player.playCurrentSong()
        player.pauseCurrentSong()
        player.togglePlayPause()
        player.seek(to: 10)
        #expect(player.currentSong == nil)
        #expect(player.currentTime == 0)

        player.setVolume(-2)
        #expect(player.volume == 0)
        player.setVolume(2)
        #expect(player.volume == 1)
        player.setVolume(0.35)
        #expect(player.volume == 0.35)
        player.setNowPlayingQueueState(canPlayPrevious: true, canPlayNext: false)
        player.setNowPlayingArtworkData(nil, for: "missing")
        player.stop()
        #expect(player.statusMessage == "Nothing playing")
    }

    @Test func audioPlayerPlayPauseSeekToggleAndStopLifecycle() {
        let player = AudioPlayer()
        let song = makeSong(duration: 120)
        var playbackEvents: [AudioPlaybackEvent] = []
        player.onPlaybackEvent = { playbackEvents.append($0) }
        player.play(song: song, url: URL(fileURLWithPath: "/dev/null"))
        #expect(player.currentSong == song)
        #expect(player.duration == 120)
        #expect(player.currentTime == 0)

        player.seek(to: -50)
        #expect(player.currentTime == 0)
        player.seek(to: 500)
        #expect(player.currentTime == 120)
        player.pauseCurrentSong()
        #expect(!player.isPlaying)
        player.playCurrentSong()
        #expect(player.isPlaying)
        player.togglePlayPause()
        #expect(!player.isPlaying)
        player.togglePlayPause()
        #expect(player.isPlaying)

        var previous = 0
        var next = 0
        player.configureRemotePlaybackCommands(onPreviousTrack: { previous += 1 }, onNextTrack: { next += 1 })
        #expect(previous == 0 && next == 0)
        player.stop()
        #expect(player.currentSong == nil)
        #expect(player.currentTime == 0)
        #expect(player.duration == 0)
        #expect(!player.isPlaying)
        #expect(playbackEvents.map(\.trigger).contains(.started))
        #expect(playbackEvents.map(\.trigger).contains(.paused))
        #expect(playbackEvents.map(\.trigger).contains(.resumed))
        #expect(playbackEvents.map(\.trigger).contains(.seeked))
        #expect(playbackEvents.map(\.trigger).contains(.stopped))
        #expect(playbackEvents.last?.snapshot.song == song)
    }

    @Test func audioPlayerCanStartAtAPersistedPositionWithoutAutoplaying() {
        let player = AudioPlayer()
        let song = makeSong(duration: 120)
        var playbackEvents: [AudioPlaybackEvent] = []
        player.onPlaybackEvent = { playbackEvents.append($0) }

        player.play(
            song: song,
            url: URL(fileURLWithPath: "/dev/null"),
            startingAt: 37,
            autoplay: false
        )

        #expect(player.currentSong == song)
        #expect(player.currentTime == 37)
        #expect(player.duration == 120)
        #expect(!player.isPlaying)
        #expect(player.hasPlayableItem)
        #expect(playbackEvents.first?.trigger == .prepared)
        player.stop()
    }

    @Test func nowPlayingControllerBuildsAndClearsMetadataAcrossBranches() throws {
        let controller = NowPlayingController()
        let song = makeSong(title: "Title", artist: "Artist", album: "Album", duration: 200)
        controller.update(song: song, isPlaying: true, elapsedTime: -5, duration: 0, canPlayPrevious: true, canPlayNext: false)
        var info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Title")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Artist")
        #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Album")
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 200)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)

        controller.setArtworkData(Data("invalid".utf8), for: "other")
        controller.setArtworkData(onePixelPNG, for: song.id)
        controller.update(song: song, isPlaying: false, elapsedTime: 10, duration: 99, canPlayPrevious: false, canPlayNext: true)
        info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 99)
        #expect(info[MPMediaItemPropertyArtwork] != nil)

        let sparse = makeSong(id: "sparse", artist: "", album: "", duration: nil)
        controller.update(song: sparse, isPlaying: false, elapsedTime: 0, duration: 0, canPlayPrevious: false, canPlayNext: false)
        info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPMediaItemPropertyArtist] == nil)
        #expect(info[MPMediaItemPropertyAlbumTitle] == nil)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)

        controller.setArtworkData(onePixelPNG, for: song.id)
        controller.update(song: nil, isPlaying: false, elapsedTime: 0, duration: 0, canPlayPrevious: false, canPlayNext: false)
        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil)
    }

    @Test func routePickerAndPreferenceReducerCoverViewBridge() {
        let avPlayer = AVPlayer()
        let controller = AirPlayRoutePickerController(player: avPlayer)
        _ = AirPlayRoutePicker(controller: controller)

        var value = AirPlayRoutePickerAnchorPreferenceKey.defaultValue
        AirPlayRoutePickerAnchorPreferenceKey.reduce(value: &value) { [:] }
        #expect(value.isEmpty)
        #expect(AirPlayRoutePickerLocation.compactPlayer != .fullPlayer)
        _ = AirPlayRoutePickerAnchor(location: .compactPlayer).body
        _ = AirPlayRoutePickerAnchor(location: .fullPlayer).body
    }
}
