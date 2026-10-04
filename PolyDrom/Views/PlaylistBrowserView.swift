//
//  PlaylistBrowserView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct PlaylistBrowserView: View {
    @ObservedObject var viewModel: AppCoordinator
    @State private var playlistPendingRename: NavidromePlaylist?
    @State private var playlistPendingDeletion: NavidromePlaylist?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button {
                    viewModel.requestPlaylistCreation()
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .disabled(!viewModel.canCreatePlaylist)
                .accessibilityIdentifier("newPlaylistButton")
            }

            if viewModel.playlists.isEmpty {
                ContentUnavailableView(
                    "No playlists yet",
                    systemImage: "music.note.list",
                    description: Text("Create a playlist, then add songs from any song menu.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyLibraryList(viewModel.playlists) { playlist in
                    playlistRow(playlist)
                }
            }
        }
        .sheet(item: $playlistPendingRename) { playlist in
            PlaylistRenameSheet(viewModel: viewModel, playlist: playlist)
        }
        .alert(
            "Delete Playlist?",
            isPresented: Binding(isPresenting: $playlistPendingDeletion),
            presenting: playlistPendingDeletion,
            actions: deletionAlertActions,
            message: deletionAlertMessage
        )
    }

    private func playlistRow(_ playlist: NavidromePlaylist) -> some View {
        NavigationLink(value: LibraryRoute.playlist(playlist)) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(playlist.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if playlist.isReadOnly {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("Read-only playlist")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                playlistPendingRename = playlist
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(!viewModel.canEdit(playlist))

            Button(role: .destructive) {
                playlistPendingDeletion = playlist
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!viewModel.canEdit(playlist))
        }
    }

    @ViewBuilder
    private func deletionAlertActions(_ playlist: NavidromePlaylist) -> some View {
        Button("Delete", role: .destructive) {
            Task {
                if await viewModel.deletePlaylist(playlist) {
                    playlistPendingDeletion = nil
                }
            }
        }
        Button("Cancel", role: .cancel) {
            playlistPendingDeletion = nil
        }
    }

    private func deletionAlertMessage(_ playlist: NavidromePlaylist) -> some View {
        Text("\(playlist.name) will be permanently deleted from Navidrome.")
    }
}

struct PlaylistDetailView: View {
    @ObservedObject var viewModel: AppCoordinator
    let playlist: NavidromePlaylist
    let openRoute: (LibraryRoute) -> Void
    var onDeleted: () -> Void = {}

    @State private var isRenamePresented = false
    @State private var isDeletePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                LibraryDetailHeader(title: currentPlaylist.name, subtitle: currentPlaylist.subtitle)

                Spacer()

                if currentPlaylist.isReadOnly {
                    Label("Read-only", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                } else if viewModel.canEdit(currentPlaylist) {
                    Button {
                        isRenamePresented = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .help("Rename playlist")

                    Button(role: .destructive) {
                        isDeletePresented = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help("Delete playlist")
                }
            }

            SongListView(
                title: "Songs",
                snapshot: viewModel.selectedPlaylist?.id == playlist.id ? viewModel.playlistSongsSnapshot : .empty,
                viewModel: viewModel,
                emptyMessage: viewModel.isBusy ? "Loading songs..." : "No songs for this playlist.",
                openRoute: openRoute,
                editablePlaylist: viewModel.canEdit(currentPlaylist) ? currentPlaylist : nil
            )
        }
        .padding(18)
        .navigationTitle(currentPlaylist.name)
        .task(id: playlist.id) {
            await viewModel.loadSongs(for: currentPlaylist)
        }
        .sheet(isPresented: $isRenamePresented) {
            PlaylistRenameSheet(viewModel: viewModel, playlist: currentPlaylist)
        }
        .alert("Delete Playlist?", isPresented: $isDeletePresented) {
            Button("Delete", role: .destructive) {
                Task {
                    if await viewModel.deletePlaylist(currentPlaylist) {
                        isDeletePresented = false
                        onDeleted()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(currentPlaylist.name) will be permanently deleted from Navidrome.")
        }
    }

    private var currentPlaylist: NavidromePlaylist {
        viewModel.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }
}

struct PlaylistCreationSheet: View {
    @ObservedObject var viewModel: AppCoordinator
    let request: PlaylistCreationRequest

    @State private var isSubmitting = false

    var body: some View {
        PlaylistNameForm(
            title: "New Playlist",
            actionTitle: "Create",
            actionIdentifier: "createPlaylistButton",
            note: request.songs.isEmpty
                ? nil
                : "\(request.songs.count) selected \(request.songs.count == 1 ? "song" : "songs") will be added.",
            isSubmitting: isSubmitting,
            submit: create,
            cancel: { viewModel.playlistCreationRequest = nil }
        )
    }

    private func create(_ name: String) {
        isSubmitting = true
        Task {
            if await viewModel.createPlaylist(name: name, songs: request.songs) {
                request.onSuccess()
                viewModel.playlistCreationRequest = nil
            } else {
                isSubmitting = false
            }
        }
    }
}

private struct PlaylistRenameSheet: View {
    @ObservedObject var viewModel: AppCoordinator
    let playlist: NavidromePlaylist

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false

    var body: some View {
        PlaylistNameForm(
            title: "Rename Playlist",
            actionTitle: "Rename",
            actionIdentifier: "renamePlaylistButton",
            initialName: playlist.name,
            isSubmitting: isSubmitting,
            submit: rename,
            cancel: { dismiss() }
        )
    }

    private func rename(to name: String) {
        isSubmitting = true
        Task {
            if await viewModel.renamePlaylist(playlist, to: name) {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}

/// The name field and buttons shared by the sheets that create and rename a
/// playlist. `submit` receives the trimmed name, and only when it is not empty.
private struct PlaylistNameForm: View {
    let title: String
    let actionTitle: String
    let actionIdentifier: String
    let note: String?
    let isSubmitting: Bool
    let submit: (String) -> Void
    let cancel: () -> Void

    @State private var name: String

    init(
        title: String,
        actionTitle: String,
        actionIdentifier: String,
        initialName: String = "",
        note: String? = nil,
        isSubmitting: Bool,
        submit: @escaping (String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.actionIdentifier = actionIdentifier
        self.note = note
        self.isSubmitting = isSubmitting
        self.submit = submit
        self.cancel = cancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.bold())

            TextField("Playlist name", text: $name)
                .accessibilityIdentifier("playlistNameField")
                .onSubmit(submitIfValid)

            if let note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)

                Button(actionTitle, action: submitIfValid)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isSubmitting)
                    .accessibilityIdentifier(actionIdentifier)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitIfValid() {
        guard !trimmedName.isEmpty, !isSubmitting else { return }
        submit(trimmedName)
    }
}
