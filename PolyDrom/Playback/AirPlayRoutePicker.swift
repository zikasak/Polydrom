//
//  AirPlayRoutePicker.swift
//  PolyDrom
//

import AVKit
import SwiftUI

@MainActor
final class AirPlayRoutePickerController {
    fileprivate let routePicker: AVRoutePickerView

    init(player: AVPlayer) {
        let routePicker = AVRoutePickerView()
        routePicker.player = player
        routePicker.isRoutePickerButtonBordered = false
        routePicker.setRoutePickerButtonColor(.labelColor, for: .normal)
        routePicker.setRoutePickerButtonColor(.secondaryLabelColor, for: .normalHighlighted)
        routePicker.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        routePicker.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        self.routePicker = routePicker
    }
}

struct AirPlayRoutePicker: NSViewRepresentable {
    let controller: AirPlayRoutePickerController

    func makeNSView(context: Context) -> AVRoutePickerView {
        controller.routePicker
    }

    func updateNSView(_ routePicker: AVRoutePickerView, context: Context) {}
}

enum AirPlayRoutePickerLocation: Hashable {
    case compactPlayer
    case fullPlayer
}

struct AirPlayRoutePickerAnchor: View {
    let location: AirPlayRoutePickerLocation

    var body: some View {
        Color.clear
            .anchorPreference(
                key: AirPlayRoutePickerAnchorPreferenceKey.self,
                value: .bounds
            ) { [location: $0] }
            .accessibilityHidden(true)
    }
}

struct AirPlayRoutePickerAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [AirPlayRoutePickerLocation: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [AirPlayRoutePickerLocation: Anchor<CGRect>],
        nextValue: () -> [AirPlayRoutePickerLocation: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
