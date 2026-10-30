import SwiftUI
import AppKit

/// The menu shown when the user clicks the menu-bar icon.
struct MenuContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loginItem: LoginItemManager
    @EnvironmentObject var log: LogStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(statusLine)
        Text("ShellyLanMan \(ServerPaths.serverVersion ?? "–")").font(.caption)

        Divider()

        Button("Weboberfläche öffnen") { NSWorkspace.shared.open(settings.webURL) }
            .keyboardShortcut("o")
            .disabled(server.status != .running)

        Divider()

        Button("Starten") { server.start() }
            .disabled(server.status.isActive)
        Button("Stoppen") { server.stop() }
            .disabled(!server.status.isActive)
        Button("Neu starten") { server.restart() }
            .disabled(!server.status.isActive)

        Divider()

        Button("Protokoll anzeigen…") { openWindow(id: "logs"); NSApp.activate(ignoringOtherApps: true) }
        Button("Protokolldatei öffnen") { NSWorkspace.shared.open(log.logFileURL) }
        Button("Datenordner im Finder zeigen") { NSWorkspace.shared.open(ServerPaths.dataDirectory) }

        Divider()

        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        ))

        // Not `SettingsLink`: as an accessory app (LSUIElement) we are not
        // activated by opening a window, so the settings window would appear
        // behind whatever the user is looking at. Activate first, then open
        // (same pattern as the ESPHome and Matter apps).
        Button("Einstellungen…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Divider()

        Button("ShellyLanMan beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch server.status {
        case .stopped: return "ShellyLanMan gestoppt"
        case .starting: return "ShellyLanMan startet…"
        case .stopping: return "ShellyLanMan stoppt…"
        case .crashed(let reason): return "ShellyLanMan abgestürzt (\(reason))"
        case .running:
            let uptime = server.uptimeDescription.map { " · seit \($0)" } ?? ""
            return "ShellyLanMan läuft · Port \(settings.port)\(uptime)"
        }
    }
}
