import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: AppCoordinator
    @State private var serverPendingDeletion: ServerProfile?

    var body: some View {
        Form {
            connectionSection
            savedServersSection
            metadataSection
            statusSection
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .accessibilityIdentifier("serverSettings")
        .alert(
            "Delete Server?",
            isPresented: deletionAlertIsPresented,
            presenting: serverPendingDeletion,
            actions: deletionAlertActions,
            message: deletionAlertMessage
        )
    }

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Server address", text: $viewModel.serverAddress)
                .textContentType(.URL)
                .accessibilityLabel("Server address")
                .accessibilityIdentifier("serverAddressField")

            TextField("Username", text: $viewModel.username)
                .textContentType(.username)
                .accessibilityLabel("Username")
                .accessibilityIdentifier("serverUsernameField")

            SecureField("Password", text: $viewModel.password)
                .textContentType(.password)
                .accessibilityLabel("Password")
                .accessibilityIdentifier("serverPasswordField")

            HStack {
                Spacer()

                Button {
                    Task { await viewModel.connectFromForm() }
                } label: {
                    Label("Save & Connect", systemImage: "network")
                }
                .disabled(!viewModel.canConnectFromForm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saveAndConnectButton")
            }
        }
    }

    private var metadataSection: some View {
        Section("Metadata") {
            Picker("Automatic refresh", selection: $viewModel.metadataRefreshInterval) {
                ForEach(MetadataRefreshInterval.allCases) { interval in
                    Text(interval.title)
                        .tag(interval)
                }
            }
            .accessibilityIdentifier("metadataRefreshIntervalPicker")

            Text("Automatic checks run only while PolyDrom is active. You can refresh manually from the library toolbar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var savedServersSection: some View {
        Section("Saved Servers") {
            if viewModel.servers.isEmpty {
                Text("No saved servers")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.servers) { server in
                    savedServerRow(server)
                }
            }
        }
    }

    private func savedServerRow(_ server: ServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: activeServerID == server.id ? "checkmark.circle.fill" : "server.rack")
                .foregroundStyle(activeServerID == server.id ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .lineLimit(1)

                if activeServerID == server.id {
                    Text(viewModel.isOnline ? "Connected" : "Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(activeServerID == server.id ? "Reconnect" : "Connect") {
                Task { await viewModel.connect(server) }
            }
            .disabled(viewModel.isBusy)

            Button(role: .destructive) {
                serverPendingDeletion = server
            } label: {
                Label("Delete \(server.displayName)", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isBusy)
            .help("Delete server")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            HStack(spacing: 8) {
                if viewModel.isBusy || viewModel.isRefreshingMetadata {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(viewModel.statusMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var activeServerID: UUID? {
        viewModel.activeServer?.id
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { serverPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    serverPendingDeletion = nil
                }
            }
        )
    }

    @ViewBuilder
    private func deletionAlertActions(_ server: ServerProfile) -> some View {
        Button("Delete", role: .destructive) {
            viewModel.deleteServer(server)
            serverPendingDeletion = nil
        }

        Button("Cancel", role: .cancel) {
            serverPendingDeletion = nil
        }
    }

    private func deletionAlertMessage(_ server: ServerProfile) -> some View {
        Text(
            "This removes \(server.displayName), its saved password, and its cached library from this Mac."
        )
    }
}
