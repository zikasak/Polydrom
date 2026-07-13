//
//  SearchView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: AppViewModel
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Search songs", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }

                Button {
                    Task { await viewModel.search() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .disabled(viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isBusy)
            }

            SongListView(
                title: viewModel.searchResults.isEmpty ? "Try a title, artist, or album" : "Search results",
                songs: viewModel.searchResults,
                viewModel: viewModel,
                emptyMessage: "No search results.",
                openRoute: openRoute
            )
        }
    }
}
