//
//  SidebarView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppCoordinator
    var onSectionSelected: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            serverSelector
            sectionList
            Spacer()
            statusLine
        }
        .padding(14)
    }

    private var serverSelector: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Server")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Server", selection: selectedServerID) {
                Text(viewModel.servers.isEmpty ? "No saved servers" : "Select a server")
                    .tag(UUID?.none)

                ForEach(viewModel.servers) { server in
                    Text(server.displayName)
                        .tag(Optional(server.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(viewModel.isBusy || viewModel.servers.isEmpty)
            .accessibilityLabel("Server")
            .accessibilityIdentifier("serverSelector")
        }
    }

    private var selectedServerID: Binding<UUID?> {
        Binding(
            get: { viewModel.activeServer?.id },
            set: { serverID in
                guard let serverID,
                      let server = viewModel.servers.first(where: { $0.id == serverID }),
                      server.id != viewModel.activeServer?.id else { return }
                Task { await viewModel.connect(server) }
            }
        )
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(LibrarySection.allCases) { section in
                Button {
                    viewModel.selectSection(section)
                    onSectionSelected()
                } label: {
                    Label(section.rawValue, systemImage: section.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.selectedSection == section ? .primary : .secondary)
                .disabled(!viewModel.canBrowseLibrary)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if viewModel.isBusy || viewModel.isRefreshingMetadata {
                ProgressView()
                    .controlSize(.small)
            }

            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}
