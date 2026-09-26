import SwiftUI

struct SonosOutputPicker: View {
    @ObservedObject var viewModel: AppCoordinator

    var body: some View {
        Menu {
            Button {
                viewModel.switchToLocalOutput()
            } label: {
                Label("This Mac / AirPlay", systemImage: "laptopcomputer")
            }
            .disabled(viewModel.audioPlayer.route == .local)

            Divider()

            if viewModel.sonosIsDiscovering {
                Text("Searching for Sonos rooms…")
            } else if viewModel.sonosGroups.isEmpty {
                Text("No Sonos rooms found")
            }

            ForEach(viewModel.sonosGroups) { group in
                Button {
                    viewModel.selectSonosGroup(group)
                } label: {
                    Label(
                        group.name,
                        systemImage: viewModel.audioPlayer.route == .sonos(group.id)
                            ? "checkmark.circle.fill" : "hifispeaker"
                    )
                }
            }

            Divider()

            Button {
                Task { await viewModel.refreshSonosGroups() }
            } label: {
                Label("Refresh Sonos rooms", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.sonosIsDiscovering)

            if let message = viewModel.sonosMessage {
                Text(message)
            }
        } label: {
            Label("Sonos output", systemImage: "hifispeaker.fill")
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(viewModel.audioPlayer.route == .local ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 30)
        }
        .menuStyle(.borderlessButton)
        .help(outputHelp)
        .onAppear {
            if viewModel.sonosGroups.isEmpty {
                Task { await viewModel.refreshSonosGroups() }
            }
        }
    }

    private var outputHelp: String {
        if case .sonos(let groupID) = viewModel.audioPlayer.route,
           let group = viewModel.sonosGroups.first(where: { $0.id == groupID }) {
            return "Playing on \(group.name)"
        }
        return "Choose Sonos speaker"
    }
}
