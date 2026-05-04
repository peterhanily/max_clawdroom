import Foundation
import os

/// Central `os.Logger` catalogue. Replaces ad-hoc NSLog sites so logs get
/// a consistent subsystem (`com.peterhanily.max_clawdroom`), filterable
/// categories in Console.app, levels (debug / info / warning / error),
/// and Apple's default privacy redaction for string interpolation unless
/// we explicitly mark a value `.public`.
///
/// Categories roughly follow the module structure — `memory` / `session`
/// / `voice` / etc. The subsystem string is hard-coded so it matches the
/// app's bundle identifier even if tests run headless.
/// Marked `nonisolated` so subsystems running off-main (LocalOpenAIServer,
/// ClaudeCodeProcess, EnvironmentSensors's nonisolated helpers) can log
/// without hopping to MainActor just to format a line. `Logger` is
/// already Sendable; the isolation attribute just tells the compiler
/// the declarations aren't MainActor under this package's default
/// isolation policy.
nonisolated enum AppLog {
    private static let subsystem = "com.peterhanily.max_clawdroom"

    // `Logger` itself is Sendable; the default isolation makes these
    // properties MainActor, which blocks nonisolated callers (the
    // subprocess wrapper, the local HTTP server) from logging. They're
    // safe to read from anywhere — mark them `nonisolated`.
    static let app        = Logger(subsystem: subsystem, category: "app")
    static let chat       = Logger(subsystem: subsystem, category: "chat")
    static let session    = Logger(subsystem: subsystem, category: "session")
    static let memory     = Logger(subsystem: subsystem, category: "memory")
    static let settings   = Logger(subsystem: subsystem, category: "settings")
    static let soul       = Logger(subsystem: subsystem, category: "soul")
    static let voice      = Logger(subsystem: subsystem, category: "voice")
    static let autonomy   = Logger(subsystem: subsystem, category: "autonomy")
    static let pet        = Logger(subsystem: subsystem, category: "pet")
    static let keychain   = Logger(subsystem: subsystem, category: "keychain")
    static let audio      = Logger(subsystem: subsystem, category: "audio")
    static let actions    = Logger(subsystem: subsystem, category: "actions")
}
