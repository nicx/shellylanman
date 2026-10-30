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

    // MARK: Firmware-Hinweise per Mail

    /// Look for newer firmware in Shelly's index and mail a summary. The check runs
    /// in the local server (the Shellies themselves need no internet for it).
    @Published var firmwareWatch: Bool { didSet { defaults.set(firmwareWatch, forKey: Keys.firmwareWatch) } }
    @Published var checkIntervalHours: Int { didSet { defaults.set(checkIntervalHours, forKey: Keys.checkIntervalHours) } }
    /// Local mail relay (plain SMTP, no auth/TLS — the relay handles that).
    @Published var mailHost: String { didSet { defaults.set(mailHost, forKey: Keys.mailHost) } }
    @Published var mailPort: Int { didSet { defaults.set(mailPort, forKey: Keys.mailPort) } }
    @Published var mailFrom: String { didSet { defaults.set(mailFrom, forKey: Keys.mailFrom) } }
    @Published var mailTo: String { didSet { defaults.set(mailTo, forKey: Keys.mailTo) } }

    /// "id@version" pairs already announced, so each update is mailed once.
    var notifiedUpdates: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.notifiedUpdates) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Keys.notifiedUpdates) }
    }

    var mailConfig: MailConfig {
        MailConfig(host: mailHost, port: UInt16(clamping: mailPort), sender: mailFrom, recipient: mailTo)
    }

    private init() {
        port = (defaults.object(forKey: Keys.port) as? Int) ?? AppSettings.defaultPort
        autoRestart = (defaults.object(forKey: Keys.autoRestart) as? Bool) ?? true
        startOnLaunch = (defaults.object(forKey: Keys.startOnLaunch) as? Bool) ?? true
        firmwareWatch = (defaults.object(forKey: Keys.firmwareWatch) as? Bool) ?? true
        checkIntervalHours = (defaults.object(forKey: Keys.checkIntervalHours) as? Int) ?? 12
        mailHost = defaults.string(forKey: Keys.mailHost) ?? MailConfig.defaultHost
        mailPort = (defaults.object(forKey: Keys.mailPort) as? Int) ?? Int(MailConfig.defaultPort)
        mailFrom = defaults.string(forKey: Keys.mailFrom) ?? ""
        mailTo = defaults.string(forKey: Keys.mailTo) ?? ""
    }

    var webURL: URL { URL(string: "http://localhost:\(port)/")! }

    private enum Keys {
        static let port = "server.port"
        static let autoRestart = "server.autoRestart"
        static let startOnLaunch = "server.startOnLaunch"
        static let firmwareWatch = "firmware.watch"
        static let checkIntervalHours = "firmware.intervalHours"
        static let notifiedUpdates = "firmware.notified"
        static let mailHost = "mail.host"
        static let mailPort = "mail.port"
        static let mailFrom = "mail.from"
        static let mailTo = "mail.to"
    }
}
