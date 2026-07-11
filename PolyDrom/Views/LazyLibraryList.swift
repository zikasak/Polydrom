//
//  LazyLibraryList.swift
//  PolyDrom
//
//  Created by Codex on 08/07/2026.
//

import SwiftUI

private struct LibraryGridIsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var libraryGridIsScrolling: Bool {
        get { self[LibraryGridIsScrollingKey.self] }
        set { self[LibraryGridIsScrollingKey.self] = newValue }
    }
}

struct LazyLibraryList<Data, Row>: View where Data: RandomAccessCollection, Data.Element: Identifiable, Row: View {
    let items: Data
    let rowInsets: EdgeInsets
    let row: (Data.Element) -> Row

    @State private var isScrolling = false

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
            isScrolling = newPhase.isScrolling
        }
        .environment(\.libraryGridIsScrolling, isScrolling)
    }
}

struct LazyLibraryCardGrid<Data, Card>: View where Data: RandomAccessCollection, Data.Element: Identifiable, Card: View {
    let items: Data
    let minimumCardWidth: CGFloat
    let spacing: CGFloat
    let card: (Data.Element) -> Card

    @State private var isScrolling = false

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
            isScrolling = newPhase.isScrolling
        }
        .environment(\.libraryGridIsScrolling, isScrolling)
    }
}
