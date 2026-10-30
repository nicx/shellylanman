import SwiftUI
import UserNotifications

/// Owns the long-lived managers and wires up lifecycle (notifications, server
/// auto-start, clean shutdown).
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let log: LogStore
    let server: ServerController
    let watcher: FirmwareWatcher
    let loginItem: LoginItemManager
    let notifier: Notifier

    init() {
        let settings = AppSettings.shared
        let log = LogStore()
        let notifier = Notifier()
        self.settings = settings
        self.log = log
        self.notifier = notifier
        let server = ServerController(settings: settings, log: log, notifier: notifier)
        self.server = server
        self.watcher = FirmwareWatcher(settings: settings, server: server, log: log, notifier: notifier)
        self.loginItem = LoginItemManager()
    }

    func bootstrap() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // Unlike the sister apps, no automatic login-item registration on first
        // launch: ShellyLanMan is a tool to try out, not core infrastructure.
        if settings.startOnLaunch { server.start() }
        watcher.start()
    }

    func shutdown() {
        server.terminateNow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon (also set via LSUIElement)
        env.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.shutdown()
    }
}

@main
struct ShellyLanManApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let env = delegate.env

        MenuBarExtra {
            MenuContentView()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.server)
                .environmentObject(env.watcher)
                .environmentObject(env.loginItem)
                .environmentObject(env.log)
        } label: {
            MenuBarLabel(server: env.server)
        }

        Settings {
            SettingsView()
                .environmentObject(env.settings)
                .environmentObject(env.server)
                .environmentObject(env.watcher)
                .environmentObject(env.loginItem)
        }

        Window("ShellyLanMan-Protokoll", id: "logs") {
            LogView()
                .environmentObject(env.log)
                .environmentObject(env.server)
                .environmentObject(env.settings)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Monochrome menu-bar icon that reflects the server status. SF Symbols render
/// as template images, so AppKit tints them for light/dark menu bars.
struct MenuBarLabel: View {
    @ObservedObject var server: ServerController

    var body: some View {
        Image(systemName: symbolName)
            .accessibilityLabel("ShellyLanMan")
    }

    private var symbolName: String {
        switch server.status {
        case .running: return "lightswitch.on"
        case .starting, .stopping, .stopped: return "lightswitch.off"
        case .crashed: return "exclamationmark.triangle.fill"
        }
    }
}
