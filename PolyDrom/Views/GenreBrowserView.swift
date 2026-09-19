import SwiftUI

struct GenreBrowserView: View {
    @ObservedObject var viewModel: AppCoordinator

    var body: some View {
        if viewModel.genres.isEmpty {
            ContentUnavailableView("No genres in this library", systemImage: "guitars")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LazyLibraryList(viewModel.genres) { genre in
                NavigationLink(value: LibraryRoute.genre(genre)) {
                    HStack(spacing: 12) {
                        Image(systemName: "guitars")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(genre.name)
                                .font(.headline)
                                .lineLimit(1)

                            Text(genre.subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct GenreDetailView: View {
    @ObservedObject var viewModel: AppCoordinator
    let genre: NavidromeGenre
    let openRoute: (LibraryRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(genre.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(genre.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            SongListView(
                title: "Songs",
                songs: viewModel.selectedGenre?.id == genre.id ? viewModel.genreSongs : [],
                viewModel: viewModel,
                emptyMessage: viewModel.isBusy ? "Loading songs..." : "No songs for this genre.",
                openRoute: openRoute
            )
        }
        .padding(18)
        .navigationTitle(genre.name)
        .task(id: genre.id) {
            await viewModel.loadSongs(for: genre)
        }
    }
}
