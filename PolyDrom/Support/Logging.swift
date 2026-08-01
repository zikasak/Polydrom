//
//  Logging.swift
//  PolyDrom
//
//  Created by Codex on 01/08/2026.
//

import OSLog

enum AppLog {
    private static let subsystem = "uk.zikasak.PolyDrom"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let sync = Logger(subsystem: subsystem, category: "sync")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let registry = Logger(subsystem: subsystem, category: "registry")
}
