import Foundation

/// "Update server": looks up the newest ShellyLanMan release on GitHub and, on request,
/// builds it on this Mac with the same script that builds the bundled server
/// (`build-server.sh`, shipped in the app's Resources). Upstream publishes no macOS
/// binary, so a build is the only way to get a newer one.
///
/// The result goes to `ServerPaths.installedRoot/<version>/shellylanman` and wins over
/// the bundled binary once it is newer; the server restarts with it. Go and Node are
/// fetched (checksum-verified) into `ServerPaths.buildRoot` on the first update and
/// reused afterwards. Needs `git` (Xcode command line tools).
@MainActor
final class ServerUpdater: ObservableObject {
    @Published private(set) var latest: String?
    @Published private(set) var isChecking = false
    @Published private(set) var isWorking = false
    @Published private(set) var status: String?
    @Published private(set) var lastError: String?

    private let server: ServerController
    private let log: LogStore
    private let notifier: Notifier
    private var loop: Task<Void, Never>?
    private var announced: String?

    init(server: ServerController, log: LogStore, notifier: Notifier) {
        self.server = server
        self.log = log
        self.notifier = notifier
    }

    var isUpdateAvailable: Bool {
        guard let latest, let current = ServerPaths.activeVersion else { return false }
        return AppSettings.isNewer(latest, than: current)
    }

    /// Look for a release shortly after launch and then once a day.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            while !Task.isCancelled {
                await self?.checkLatest()
                try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
            }
        }
    }

    func checkLatest() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/wimmme/shellylanman/releases/latest")!)
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let tag = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String else {
                throw URLError(.badServerResponse)
            }
            latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            lastError = nil
            if isUpdateAvailable, let latest, announced != latest {
                announced = latest
                log.appendSystem("ShellyLanMan \(latest) ist verfügbar (läuft: \(ServerPaths.activeVersion ?? "?"))")
                notifier.oneShot(title: "ShellyLanMan \(latest) verfügbar",
                                 body: "Im Menü „ShellyLanMan aktualisieren“ wählen.")
            }
        } catch {
            lastError = "Versionsabfrage fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Build the newest release, install it and restart the server with it.
    func install() async {
        guard !isWorking else { return }
        if latest == nil { await checkLatest() }
        guard let target = latest, isUpdateAvailable else {
            lastError = "Kein neueres ShellyLanMan gefunden"
            return
        }
        guard let script = Bundle.main.url(forResource: "build-server", withExtension: "sh") else {
            lastError = "build-server.sh fehlt im App-Bundle"
            return
        }
        isWorking = true
        lastError = nil
        status = "Baue ShellyLanMan \(target)… (beim ersten Mal ein paar Minuten)"
        log.appendSystem("Server-Update auf \(target): Build startet")
        defer { isWorking = false; status = nil }

        let work = ServerPaths.buildRoot
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let exitCode = await runBuild(script: script, ref: "v\(target)", work: work)
        guard exitCode == 0 else {
            lastError = "Build fehlgeschlagen (Exit \(exitCode)), Einzelheiten im Protokoll"
            log.appendSystem("Server-Update: Build fehlgeschlagen (Exit \(exitCode))")
            return
        }
        do {
            try installBuilt(from: work)
        } catch {
            lastError = "Installation fehlgeschlagen: \(error.localizedDescription)"
            log.appendSystem("Server-Update: Installation fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        log.appendSystem("Server-Update: ShellyLanMan \(ServerPaths.serverVersion ?? target) installiert — starte neu")
        notifier.oneShot(title: "ShellyLanMan aktualisiert", body: "Läuft jetzt mit Version \(ServerPaths.serverVersion ?? target).")
        server.restart()
    }

    private func runBuild(script: URL, ref: String, work: URL) async -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["UPSTREAM_REF"] = ref
        env["BUILD_ROOT"] = work.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.log.append(text) }
        }
        return await withCheckedContinuation { continuation in
            proc.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try proc.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }

    /// Copy the fresh binary to `<installedRoot>/<version>/` and point `current` at it.
    private func installBuilt(from work: URL) throws {
        let fm = FileManager.default
        let built = work.appendingPathComponent("Vendored/shellylanman")
        let info = try String(contentsOf: work.appendingPathComponent("Vendored/shellylanman.version"), encoding: .utf8)
        let lines = info.split(whereSeparator: \.isNewline).map(String.init)
        guard let version = lines.first, !version.isEmpty, fm.isExecutableFile(atPath: built.path) else {
            throw NSError(domain: "ShellyLanMan", code: 2, userInfo: [NSLocalizedDescriptionKey: "Build-Ergebnis unvollständig"])
        }
        let previous = ServerPaths.installed?.version
        let dir = ServerPaths.installedRoot.appendingPathComponent(version, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("shellylanman")
        try? fm.removeItem(at: target)
        try fm.copyItem(at: built, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try info.write(to: ServerPaths.installedRoot.appendingPathComponent("current"), atomically: true, encoding: .utf8)
        // Keep the previous version as a fallback, drop anything older.
        let keep: Set<String> = [version, previous ?? version]
        for name in (try? fm.contentsOfDirectory(atPath: ServerPaths.installedRoot.path)) ?? []
        where name != "current" && !keep.contains(name) {
            try? fm.removeItem(at: ServerPaths.installedRoot.appendingPathComponent(name))
        }
    }
}
