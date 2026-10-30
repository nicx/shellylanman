import Foundation

/// User-facing configuration, persisted in `UserDefaults`.
///
/// Every property writes through to `UserDefaults` on `didSet` so that the
/// `ServerController` always reads the current values, and SwiftUI views can
/// bind directly via `@Published`.
///
/// Only what the server needs before its web UI is up lives here (port);
/// everything else is configured in ShellyLanMan's own web UI.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// ShellyLanMan's default web UI port.
    static let defaultPort = 3082

    /// `SHELLYLANMAN_PORT`. The server always listens on all interfaces: the
    /// Shellies fetch locally served firmware from this port.
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    @Published var autoRestart: Bool { didSet { defaults.set(autoRestart, forKey: Keys.autoRestart) } }
    /// Start the service as soon as the app launches (and so at login, when
    /// the app is a login item).
    @Published var startOnLaunch: Bool { didSet { defaults.set(startOnLaunch, forKey: Keys.startOnLaunch) } }

    private init() {
        port = (defaults.object(forKey: Keys.port) as? Int) ?? AppSettings.defaultPort
        autoRestart = (defaults.object(forKey: Keys.autoRestart) as? Bool) ?? true
        startOnLaunch = (defaults.object(forKey: Keys.startOnLaunch) as? Bool) ?? true
    }

    var webURL: URL { URL(string: "http://localhost:\(port)/")! }

    private enum Keys {
        static let port = "server.port"
        static let autoRestart = "server.autoRestart"
        static let startOnLaunch = "server.startOnLaunch"
    }
}
