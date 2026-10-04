//
//  LibraryCardView.swift
//  PolyDrom
//

import SwiftUI

/// A cover with a title and a summary line, as shown in the album and artist grids.
struct LibraryCardView: View {
    static let coverSize: CGFloat = 128

    let title: String
    let subtitle: String
    let coverArtResource: CoverArtResource?
    var spacing: CGFloat = 9
    var subtitleLineLimit = 2
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            CoverArtView(resource: coverArtResource, size: Self.coverSize)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    /// Opens a library card when it is pressed and pins a favorite toggle to the
    /// corner of its cover.
    ///
    /// Cards scroll into view by the dozen, and a button or navigation link
    /// costs several times what a tap gesture does to build, so both the card
    /// and its badge are plain views with gestures.
    func libraryCardActions(
        isFavorite: Bool,
        isOnline: Bool,
        favoriteHelp: String,
        open: @escaping () -> Void,
        toggleFavorite: @escaping () -> Void
    ) -> some View {
        modifier(LibraryCardPressModifier(action: open))
            // The cover is centered in a card whose width follows the window, so
            // the badge is placed relative to the cover rather than the card.
            .overlay(alignment: .top) {
                LibraryFavoriteBadge(
                    isFavorite: isFavorite,
                    isEnabled: isOnline,
                    help: favoriteHelp,
                    toggle: toggleFavorite
                )
                .padding(5)
                .frame(width: LibraryCardView.coverSize, alignment: .trailing)
                .padding(.top, 10)
            }
    }
}

/// Makes a library card behave like a plain button, without a button's cost of
/// building one per card during scrolling: it dims while pressed, and opens
/// when the press is released inside it.
struct LibraryCardPressModifier: ViewModifier {
    let action: () -> Void

    @GestureState private var isPressed = false
    @State private var bounds = Bounds()

    /// A reference, so recording the card's size never re-renders it.
    private final class Bounds {
        var size = CGSize.zero

        func contains(_ location: CGPoint) -> Bool {
            CGRect(origin: .zero, size: size).contains(location)
        }
    }

    func body(content: Content) -> some View {
        content
            .opacity(isPressed ? 0.6 : 1)
            .onGeometryChange(for: CGSize.self, of: \.size) { size in
                bounds.size = size
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { [bounds] value, isPressed, _ in
                        isPressed = bounds.contains(value.location)
                    }
                    .onEnded { [bounds] value in
                        if bounds.contains(value.location) {
                            action()
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// The favorite toggle shown over a library card.
struct LibraryFavoriteBadge: View {
    let isFavorite: Bool
    let isEnabled: Bool
    let help: String
    let toggle: () -> Void

    var body: some View {
        Image(systemName: isFavorite ? "heart.fill" : "heart")
            .opacity(isEnabled ? 1 : 0.5)
            .padding(7)
            // A translucent fill instead of a material: a material is a live blur
            // of the cover behind it, recomposited for every badge on each frame.
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: Circle())
            .contentShape(Circle())
            .onTapGesture {
                // The tap is always taken so it never opens the card underneath.
                if isEnabled {
                    toggle()
                }
            }
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
            .accessibilityAddTraits(.isButton)
            .help(help)
    }
}
