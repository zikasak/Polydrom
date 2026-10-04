import Foundation

enum AppDirectories {
    /// PolyDrom's folder in Application Support, which holds everything that
    /// has to outlive the disposable caches.
    static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PolyDrom", isDirectory: true)
    }
}
