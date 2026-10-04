//
//  LazyLibraryList.swift
//  PolyDrom
//
//  Created by Codex on 08/07/2026.
//

import SwiftUI

/// Scroll activity shared with the covers inside a lazy container. It is an
/// observable reference so a phase change re-renders only the covers that are
/// still waiting for an image instead of every visible row.
@Observable
final class LibraryScrollActivity {
    var isScrolling = false
}

struct LazyLibraryList<Data, Row>: View where Data: RandomAccessCollection, Data.Element: Identifiable, Row: View {
    let items: Data
    let rowInsets: EdgeInsets
    let row: (Data.Element) -> Row

    @State private var scrollActivity = LibraryScrollActivity()

    init(
        _ items: Data,
        rowInsets: EdgeInsets = EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8),
        @ViewBuilder row: @escaping (Data.Element) -> Row
    ) {
        self.items = items
        self.rowInsets = rowInsets
        self.row = row
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    row(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(rowInsets)
                }
            }
            .padding(.vertical, 4)
        }
        .onScrollPhaseChange { _, newPhase in
            scrollActivity.isScrolling = newPhase.isScrolling
        }
        .environment(scrollActivity)
    }
}

struct LazyLibraryCardGrid<Data, Card>: View where Data: RandomAccessCollection, Data.Element: Identifiable, Card: View {
    let items: Data
    let minimumCardWidth: CGFloat
    let spacing: CGFloat
    let card: (Data.Element) -> Card

    @State private var scrollActivity = LibraryScrollActivity()

    init(
        _ items: Data,
        minimumCardWidth: CGFloat = 150,
        spacing: CGFloat = 14,
        @ViewBuilder card: @escaping (Data.Element) -> Card
    ) {
        self.items = items
        self.minimumCardWidth = minimumCardWidth
        self.spacing = spacing
        self.card = card
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: minimumCardWidth), spacing: spacing, alignment: .top)],
                alignment: .leading,
                spacing: spacing
            ) {
                ForEach(items) { item in
                    card(item)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .onScrollPhaseChange { _, newPhase in
            scrollActivity.isScrolling = newPhase.isScrolling
        }
        .environment(scrollActivity)
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
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? 1 : 0.5)
            .padding(7)
            // An opaque fill instead of a material: a material is a live blur of
            // the cover behind it, recomposited for every badge on each frame.
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: Circle())
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
