import AppKit
import SwiftUI

struct SonosOutputPicker: View {
    @ObservedObject var viewModel: AppCoordinator
    // Route lives on the player, so observe it directly to redraw when output changes.
    @ObservedObject private var audioPlayer: AudioPlayer

    init(viewModel: AppCoordinator) {
        self.viewModel = viewModel
        self.audioPlayer = viewModel.audioPlayer
    }

    var body: some View {
        Menu {
            if let activeGroupName {
                Text("Playing on \(activeGroupName)")
                Divider()
            }

            Toggle(isOn: localBinding) {
                Label("This Mac / AirPlay", systemImage: "laptopcomputer")
            }

            Divider()

            if viewModel.sonosIsDiscovering {
                Text("Searching for Sonos rooms…")
            } else if viewModel.sonosGroups.isEmpty {
                Text("No Sonos rooms found")
            }

            ForEach(viewModel.sonosGroups) { group in
                Toggle(isOn: binding(for: group)) {
                    Label(
                        group.name,
                        systemImage: isActive(group) ? "hifispeaker.fill" : "hifispeaker"
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
            outputIcon
                .frame(width: 32, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // Menus stretch and shrink like buttons; keep the icon from collapsing in narrow windows.
        .fixedSize()
        .help(outputHelp)
        .accessibilityLabel("Sonos output")
        .accessibilityValue(activeGroupName.map { "Playing on \($0)" } ?? "This Mac")
        .onAppear {
            if viewModel.sonosGroups.isEmpty {
                Task {
                    await viewModel.refreshSonosGroups(
                        retryDelays: [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
                    )
                }
            }
        }
    }

    private var activeGroupID: String? {
        if case .sonos(let groupID) = audioPlayer.route { return groupID }
        return nil
    }

    private var activeGroupName: String? {
        guard let activeGroupID else { return nil }
        return viewModel.sonosGroups.first { $0.id == activeGroupID }?.name
            ?? viewModel.sonosSession?.group.name
            ?? "Sonos"
    }

    private func isActive(_ group: SonosGroup) -> Bool {
        activeGroupID == group.id
    }

    private var localBinding: Binding<Bool> {
        Binding(
            get: { activeGroupID == nil },
            set: { if $0, activeGroupID != nil { viewModel.switchToLocalOutput() } }
        )
    }

    private func binding(for group: SonosGroup) -> Binding<Bool> {
        Binding(
            get: { isActive(group) },
            set: { if $0, !isActive(group) { viewModel.selectSonosGroup(group) } }
        )
    }

    /// Menu labels drop SwiftUI foreground styles on macOS, so the active state
    /// is baked into a non-template image. The outline symbol keeps the speaker
    /// cones readable when tinted; the filled one turns into a solid block.
    private var outputIcon: Image {
        let symbol = "hifispeaker"
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        var configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        if activeGroupID != nil {
            configuration = configuration.applying(.init(paletteColors: [.controlAccentColor]))
        }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sonos output")?
            .withSymbolConfiguration(configuration) else {
            return Image(systemName: symbol)
        }
        image.isTemplate = activeGroupID == nil
        return Image(nsImage: image)
    }

    private var outputHelp: String {
        activeGroupName.map { "Playing on \($0)" } ?? "Choose Sonos speaker"
    }
}
