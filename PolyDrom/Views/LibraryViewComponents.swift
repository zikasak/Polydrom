//
//  LibraryViewComponents.swift
//  PolyDrom
//

import SwiftUI

/// The label of a button that toggles a favorite.
struct FavoriteLabel: View {
    let isFavorite: Bool

    var body: some View {
        Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
    }
}

/// The name and summary line at the top of an album, artist, genre, or playlist page.
struct LibraryDetailHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

extension Binding where Value == Bool {
    /// True while `item` has a value; dismissing the presentation clears it.
    init<Item: Sendable>(isPresenting item: Binding<Item?>) {
        self.init(
            get: { item.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    item.wrappedValue = nil
                }
            }
        )
    }
}
