//
//  SidebarView.swift
//  PolyDrom
//
//  Created by zikasak on 07/07/2026.
//

import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    var onSectionSelected: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionForm
            savedServers
            sectionList
            Spacer()
            statusLine
        }
        .padding(14)
        .navigationTitle("PolyDrom")
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Server address", text: $viewModel.serverAddress)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Server address")

            TextField("Username", text: $viewModel.username)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Username")

            SecureField("Password", text: $viewModel.password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Password")

            Button {
                Task { await viewModel.connectFromForm() }
            } label: {
                Label("Save & Connect", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isBusy || viewModel.serverAddress.isEmpty || viewModel.username.isEmpty)
            .buttonStyle(.borderedProminent)
        }
    }

    private var savedServers: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Servers")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.servers.isEmpty {
                Text("No saved servers")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.servers) { server in
                    HStack(spacing: 6) {
                        Button {
                            Task { await viewModel.connect(server) }
                        } label: {
                            Label(server.displayName, systemImage: viewModel.activeServer?.id == server.id ? "checkmark.circle.fill" : "server.rack")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isBusy)

                        Button {
                            viewModel.deleteServer(server)
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete server")
                    }
                }
            }
        }
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
                .disabled(!viewModel.isConnected)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if viewModel.isBusy {
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
