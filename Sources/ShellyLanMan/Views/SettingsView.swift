import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var loginItem: LoginItemManager

    var body: some View {
        Form {
            Section {
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                Toggle("Dienst beim Start der App starten", isOn: $settings.startOnLaunch)
                Toggle("Bei Absturz automatisch neu starten", isOn: $settings.autoRestart)
                HStack {
                    Text("Änderungen werden beim nächsten Start wirksam.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Übernehmen & neu starten") { server.restart() }
                        .disabled(!server.status.isActive)
                }
            } header: {
                Text("Dienst")
            } footer: {
                Text("Standard ist Port \(String(AppSettings.defaultPort)). ShellyLanMan lauscht immer auf allen Netzwerkschnittstellen, weil die Shellies lokal ausgelieferte Firmware von diesem Port laden. Ohne UI-Passwort (Weboberfläche → Settings → Security) kann jeder im Netz es bedienen.")
            }

            Section("Start") {
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if let err = loginItem.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("ShellyLanMan") {
                LabeledContent("Version", value: ServerPaths.serverVersion ?? "–")
                LabeledContent("Daten") {
                    Button(ServerPaths.dataDirectory.path) {
                        NSWorkspace.shared.open(ServerPaths.dataDirectory)
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Protokoll") {
                    Button(ServerPaths.logsDirectory.path) {
                        NSWorkspace.shared.open(ServerPaths.logsDirectory)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
