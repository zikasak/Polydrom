import Foundation

enum PlaybackTime {
    /// Minutes and seconds, e.g. "3:05". Minutes are not folded into hours.
    static func text(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        return text(Int(seconds.rounded(.down)))
    }
}
