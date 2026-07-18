//
//  OpenInSpotifyLink.swift
//  PolyDrom
//

import SwiftUI

struct OpenInSpotifyLink: View {
    enum Presentation {
        case labeled
        case iconOnly
    }

    let destination: URL
    let presentation: Presentation

    init(album: NavidromeAlbum, presentation: Presentation = .labeled) {
        destination = SpotifySearchLink.url(for: album)
        self.presentation = presentation
    }

    init(artist: NavidromeArtist, presentation: Presentation = .labeled) {
        destination = SpotifySearchLink.url(for: artist)
        self.presentation = presentation
    }

    var body: some View {
        Link(destination: destination) {
            label
        }
        .help("Search on Spotify")
    }

    @ViewBuilder
    private var label: some View {
        switch presentation {
        case .labeled:
            Label("Open in Spotify", systemImage: "arrow.up.right.square")
        case .iconOnly:
            Image("SpotifyIcon")
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityLabel("Open in Spotify")
        }
    }
}
