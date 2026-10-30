import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var server: ServerController
    @EnvironmentObject var watcher: FirmwareWatcher
    @EnvironmentObject var loginItem: LoginItemManager

    @State private var token = TokenStore.load() ?? ""
    @State private var testResult: String?

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

            Section {
                Toggle("Auf neue Firmware prüfen und per Mail melden", isOn: $settings.firmwareWatch)
                Stepper("Prüfen alle \(settings.checkIntervalHours) Stunden", value: $settings.checkIntervalHours, in: 1...168)
                TextField("Mail-Relay (Host)", text: $settings.mailHost)
                TextField("Relay-Port", value: $settings.mailPort, format: .number.grouping(.never))
                TextField("Absender", text: $settings.mailFrom)
                TextField("Empfänger", text: $settings.mailTo)
                SecureField("API-Token (nur lesen, falls UI-Passwort gesetzt)", text: $token)
                    .onChange(of: token) { TokenStore.save(token) }
                HStack {
                    Button("Testmail senden") {
                        testResult = "…"
                        Task { testResult = await watcher.sendTestMail() }
                    }
                    Button("Jetzt prüfen") { Task { await watcher.check() } }
                        .disabled(server.status != .running || watcher.isChecking)
                    Spacer()
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                }
                Text(watcher.summary).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Firmware-Hinweise")
            } footer: {
                Text("Der Server fragt Shellys Firmware-Index ab, die Shellies selbst brauchen dafür kein Internet. Das Mail-Relay nimmt Klartext-SMTP an und liefert weiter. Mit UI-Passwort braucht die App einen Token mit Zugriffsstufe „read“ aus der Weboberfläche (Settings → MCP).")
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
