import Foundation

/// Asks the local ShellyLanMan server (`GET /api/v1/firmware`) which devices have
/// newer stable firmware, and mails a summary when an update shows up that was not
/// announced before.
///
/// It uses `GET /api/v1/firmware/index` (Shelly's public index vs. the version each device
/// reported). `/api/v1/firmware` would have every device run `Shelly.CheckForUpdate` first,
/// which takes minutes when the Shellies have no internet. On 2026-11-11 a long-running server in that mode
/// kept answering 2.1.1 from its index data while a freshly started one saw 2.2.0
/// from the same index, so a stale index cache hid every update (cause not found).
///
@MainActor
final class FirmwareWatcher: ObservableObject {
    struct Pending: Equatable {
        let id: String
        let name: String
        let model: String
        let current: String
        let latest: String
        var key: String { "\(id)@\(latest)" }
    }

    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var pending: [Pending] = []
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let server: ServerController
    private let log: LogStore
    private let notifier: Notifier
    private var loop: Task<Void, Never>?
    /// Set after a check in which Shelly's index answered for (almost) nothing: try again
    /// sooner than the normal interval.
    private var retryAt: Date?

    init(settings: AppSettings, server: ServerController, log: LogStore, notifier: Notifier) {
        self.settings = settings
        self.server = server
        self.log = log
        self.notifier = notifier
    }

    /// Wake up every minute; check once the server is up and the interval has passed.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            // Give the server time to find devices before the first look.
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.firmwareWatch, self.server.status == .running, self.isDue {
                    await self.check()
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private var isDue: Bool {
        if let retryAt { return Date() >= retryAt }
        guard let lastCheck else { return true }
        return Date().timeIntervalSince(lastCheck) >= Double(max(1, settings.checkIntervalHours)) * 3600
    }

    var summary: String {
        if isChecking { return "Firmware-Prüfung läuft…" }
        if let lastError { return "Firmware-Prüfung: \(lastError)" }
        guard let lastCheck else { return "Firmware noch nicht geprüft" }
        let time = Self.timeFormatter.string(from: lastCheck)
        return pending.isEmpty
            ? "Firmware aktuell (geprüft \(time))"
            : "\(pending.count) Firmware-Update\(pending.count == 1 ? "" : "s") verfügbar (geprüft \(time))"
    }

    // MARK: - Check

    func check() async {
        guard !isChecking else { return }
        guard server.status == .running else {
            lastError = "Dienst läuft nicht"
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            async let devices = fetch([DeviceRow].self, "/api/v1/devices")
            async let index = fetch([IndexRow].self, "/api/v1/firmware/index")
            let (deviceRows, indexRows) = try await (devices, index)
            let byID = Dictionary(deviceRows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let found = indexRows.filter { $0.newer && !($0.latest ?? "").isEmpty }.map { row -> Pending in
                let dev = byID[row.id]
                let name = [dev?.name, dev?.hostname].compactMap { $0 }.first { !$0.isEmpty } ?? row.id
                return Pending(id: row.id, name: name, model: dev?.typeName ?? "",
                               current: row.current ?? "?", latest: row.latest ?? "?")
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let failedIDs = Set(indexRows.filter { !($0.error ?? "").isEmpty }.map(\.id))
            let failed = failedIDs.count
            if !indexRows.isEmpty, failed * 2 > indexRows.count {
                // Shelly's server answered with errors (408/502 happen): what we know stays,
                // and the server keeps such errors for a while, so wait a bit before retrying.
                lastError = "Shellys Index antwortet für \(failed) von \(indexRows.count) Geräten nicht"
                retryAt = Date().addingTimeInterval(30 * 60)
                log.appendSystem("Firmware-Prüfung unvollständig: \(lastError!), neuer Versuch in 30 Min.")
                return
            }
            retryAt = nil
            lastError = nil
            lastCheck = Date()
            pending = found
            log.appendSystem("Firmware geprüft: \(indexRows.count) Geräte, \(found.count) mit Update"
                + (failed > 0 ? ", \(failed) ohne Antwort" : ""))
            await announce(found, unresolved: failedIDs)
        } catch {
            lastError = error.localizedDescription
            log.appendSystem("Firmware-Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Mail (and notification) only when something is new; the mail lists everything pending.
    private func announce(_ found: [Pending], unresolved: Set<String>) async {
        let known = settings.notifiedUpdates
        // Devices Shelly did not answer for keep their "announced" mark: no re-mail as NEU later.
        let current = Set(found.map(\.key)).union(known.filter { key in unresolved.contains { key.hasPrefix($0 + "@") } })
        let fresh = found.filter { !known.contains($0.key) }
        guard !fresh.isEmpty else {
            settings.notifiedUpdates = current // forget updates that were installed meanwhile
            return
        }
        notifier.oneShot(title: "Shelly-Firmware verfügbar",
                         body: fresh.count == 1 ? "\(fresh[0].name): \(fresh[0].current) → \(fresh[0].latest)"
                                                : "Für \(fresh.count) Geräte gibt es neue Firmware.")
        let cfg = settings.mailConfig
        guard cfg.isConfigured else {
            log.appendSystem("Neue Firmware gefunden, aber Mail ist nicht konfiguriert")
            settings.notifiedUpdates = current
            return
        }
        let freshKeys = Set(fresh.map(\.key))
        let body = Self.mailBody(found, freshKeys: freshKeys)
        let subject = "Shelly-Firmware: \(fresh.count) neue\(fresh.count == 1 ? "s" : "") Update\(fresh.count == 1 ? "" : "s")"
        let error = await Task.detached { MailSender.send(cfg, subject: subject, body: body) }.value
        if let error {
            // Not marked as announced: the next check tries again.
            log.appendSystem("Mailversand fehlgeschlagen: \(error)")
            lastError = "Mailversand fehlgeschlagen"
        } else {
            settings.notifiedUpdates = current
            log.appendSystem("Mail zu \(fresh.count) neuen Firmware-Updates gesendet")
        }
    }

    func sendTestMail() async -> String {
        let cfg = settings.mailConfig
        let error = await Task.detached {
            MailSender.send(cfg, subject: "ShellyLanMan: Testmail",
                            body: "Die Mailbenachrichtigung für Shelly-Firmware-Updates funktioniert.")
        }.value
        return error ?? "Testmail gesendet."
    }

    nonisolated private static func mailBody(_ found: [Pending], freshKeys: Set<String>) -> String {
        var lines = ["Für diese Shelly-Geräte gibt es neue stabile Firmware:", ""]
        for p in found {
            let mark = freshKeys.contains(p.key) ? "NEU " : "    "
            lines.append("\(mark)\(p.name) (\(p.model)): \(p.current) → \(p.latest)")
        }
        lines += ["", "Änderungen (Gen2+): https://shelly-api-docs.shelly.cloud/gen2/changelog/",
                  "", "Update über ShellyLanMan oder Home Assistant."]
        return lines.joined(separator: "\n")
    }

    // MARK: - HTTP

    private struct DeviceRow: Decodable {
        let id: String
        let name: String?
        let hostname: String?
        let typeName: String?
    }

    /// `GET /api/v1/firmware/index`: cached device data compared with Shelly's index.
    /// Unlike `/api/v1/firmware` no device is asked, so it answers in seconds.
    private struct IndexRow: Decodable {
        let id: String
        let current: String?
        let latest: String?
        let newer: Bool
        let error: String?
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.port)\(path)")!)
        request.timeoutInterval = 150
        if let token = TokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 401: throw NSError(domain: "ShellyLanMan", code: 401, userInfo: [NSLocalizedDescriptionKey:
            "UI-Passwort aktiv — in den Einstellungen den API-Token (nur lesen) hinterlegen"])
        default: throw NSError(domain: "ShellyLanMan", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey:
            "Server antwortet mit HTTP \(http.statusCode)"])
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM. HH:mm"
        return f
    }()
}
