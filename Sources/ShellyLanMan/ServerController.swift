import Foundation

/// Supervises the ShellyLanMan Go process: start/stop/restart with crash
/// detection, exponential-backoff keepalive and log capture.
@MainActor
final class ServerController: ObservableObject {

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case crashed(String)

        var isActive: Bool {
            switch self {
            case .running, .starting: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?

    private let settings: AppSettings
    private let log: LogStore
    private let notifier: Notifier

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Set while we are deliberately stopping, so the termination handler does
    /// not treat the exit as a crash and restart it.
    private var intentionalStop = false
    /// Set when a restart was requested; the relaunch happens once the current
    /// process has fully terminated (see `handleTermination`).
    private var startAfterStop = false
    private var isStarting = false
    private var restartAttempt = 0
    private var pendingRestart: DispatchWorkItem?
    private let backoffSeconds: [Double] = [1, 2, 5, 10, 30, 60]
    /// After this many consecutive failed auto-restarts, escalate with a
    /// distinct notification (once per episode).
    private let restartEscalateThreshold = 5
    private var escalatedThisEpisode = false

    init(settings: AppSettings, log: LogStore, notifier: Notifier) {
        self.settings = settings
        self.log = log
        self.notifier = notifier
    }

    // MARK: - Public control

    var isRunning: Bool { process != nil }

    func start() {
        guard process == nil, !isStarting else {
            log.appendSystem("Start ignoriert: läuft bereits")
            return
        }
        pendingRestart?.cancel()
        pendingRestart = nil
        Task { await startAsync() }
    }

    private func startAsync() async {
        isStarting = true
        defer { isStarting = false }
        intentionalStop = false
        do {
            try ServerPaths.validate()
            try FileManager.default.createDirectory(at: ServerPaths.dataDirectory, withIntermediateDirectories: true)
            // Clear an orphaned instance still holding the port right before
            // launching, so the takeover window is as short as possible.
            await reclaimOrphan()
            try launch()
        } catch {
            status = .crashed(error.localizedDescription)
            lastError = error.localizedDescription
            log.appendSystem("Start fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Stop the server intentionally (no keepalive restart).
    func stop() {
        intentionalStop = true
        pendingRestart?.cancel()
        pendingRestart = nil
        terminateProcess()
    }

    func restart() {
        log.appendSystem("Neustart angefordert")
        if process != nil {
            startAfterStop = true
            stop()
        } else {
            start()
        }
    }

    /// Synchronously terminate the child before the app exits, so no orphaned
    /// server process survives.
    func terminateNow() {
        intentionalStop = true
        startAfterStop = false
        pendingRestart?.cancel()
        pendingRestart = nil
        guard let proc = process, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        // ShellyLanMan saves its device archive on SIGTERM; give it a moment.
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { kill(pid, SIGKILL) }
    }

    var uptimeDescription: String? {
        guard status == .running, let startedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if d > 0 { return String(format: "%dd %02dh", d, h) }
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    // MARK: - Orphan takeover

    /// A hard app crash skips `terminateNow()`, and the orphaned server keeps
    /// holding the port: every keepalive attempt would then die at once with
    /// "address already in use". Same remedy as the sister apps: if the port is
    /// held by a process whose command line proves it is OUR binary, shut it
    /// down (SIGTERM, escalating to SIGKILL). Anything else is left alone.
    private func reclaimOrphan() async {
        guard let pid = orphanPID() else { return }
        log.appendSystem("Verwaiste ShellyLanMan-Instanz (PID \(pid)) belegt Port \(settings.port) — wird für die Übernahme beendet")
        kill(pid, SIGTERM)
        if await portReleased(within: 10) {
            log.appendSystem("Verwaiste Instanz beendet — übernehme")
            return
        }
        log.appendSystem("Verwaiste Instanz reagiert nicht auf SIGTERM — SIGKILL")
        kill(pid, SIGKILL)
        if !(await portReleased(within: 5)) {
            log.appendSystem("Port \(settings.port) weiterhin belegt — Start wird vermutlich scheitern")
        }
    }

    private func portReleased(within seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !portIsHeld() { return true }
        }
        return false
    }

    private func orphanPID() -> pid_t? {
        guard portIsHeld(), let pid = portListenerPID() else { return nil }
        guard pid > 0, pid != process?.processIdentifier else { return nil }
        guard kill(pid, 0) == 0 else { return nil }
        guard let command = processCommand(pid),
              command.hasPrefix(ServerPaths.binaryURL.path) else {
            log.appendSystem("Port \(settings.port) ist belegt, aber PID \(pid) ist nicht unser ShellyLanMan — kein Eingriff")
            return nil
        }
        return pid
    }

    /// Whether someone listens on our port, probed by binding it ourselves on
    /// all interfaces with `SO_REUSEADDR` (the server listens on `[::]`, which
    /// covers IPv4 too), so a socket lingering in TIME_WAIT does not read as a
    /// live instance.
    private func portIsHeld() -> Bool {
        guard let port = UInt16(exactly: settings.port), port > 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0).bigEndian
        let result = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return false }
        return errno == EADDRINUSE
    }

    /// PID listening on our port, via `lsof`. Nil unless exactly one process
    /// holds it.
    private func portListenerPID() -> pid_t? {
        let output = runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(settings.port)", "-sTCP:LISTEN", "-t"]) ?? ""
        let pids = Set(output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) })
        guard pids.count == 1 else { return nil }
        return pids.first
    }

    private func processCommand(_ pid: pid_t) -> String? {
        runTool("/bin/ps", ["-p", "\(pid)", "-o", "command="])
    }

    private func runTool(_ path: String, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: - Process lifecycle

    private func launch() throws {
        let proc = Process()
        proc.executableURL = ServerPaths.binaryURL
        proc.currentDirectoryURL = ServerPaths.dataDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["SHELLYLANMAN_DATA"] = ServerPaths.dataDirectory.path
        environment["SHELLYLANMAN_PORT"] = String(settings.port)
        proc.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        installReader(outPipe)
        installReader(errPipe)

        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            let reason = finished.terminationReason
            DispatchQueue.main.async {
                self?.handleTermination(code: code, reason: reason)
            }
        }

        intentionalStop = false
        status = .starting
        startedAt = nil
        lastError = nil
        log.appendSystem("Starte ShellyLanMan \(ServerPaths.serverVersion ?? "") auf Port \(settings.port)")

        try proc.run()
        process = proc
        stdoutPipe = outPipe
        stderrPipe = errPipe

        Task { await awaitReady(proc) }
    }

    /// Mark the server running once its port actually accepts connections,
    /// rather than on a mere spawn.
    private func awaitReady(_ proc: Process) async {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard process === proc, status == .starting else { return }
            if Self.canConnect(host: "127.0.0.1", port: settings.port) {
                status = .running
                startedAt = Date()
                restartAttempt = 0
                escalatedThisEpisode = false
                log.appendSystem("Bereit auf Port \(settings.port)")
                notifier.report(serverHealthy: true)
                return
            }
        }
        log.appendSystem("ShellyLanMan öffnet den Port nicht (60 s) — bleibt im Status „startet“")
    }

    /// Plain TCP connect probe.
    nonisolated private static func canConnect(host: String, port: Int) -> Bool {
        guard let p = UInt16(exactly: port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = p.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let result = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func installReader(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.log.append(text)
            }
        }
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else { return }
        if status == .running || status == .starting { status = .stopping }
        proc.terminate() // SIGTERM
        let pid = proc.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func handleTermination(code: Int32, reason: Process.TerminationReason) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        startedAt = nil

        if intentionalStop {
            status = .stopped
            log.appendSystem("Dienst gestoppt")
            notifier.clear()
            escalatedThisEpisode = false
            if startAfterStop {
                startAfterStop = false
                start()
            }
            return
        }

        let bySignal = (reason == .uncaughtSignal)
        // ShellyLanMan exits 0 on SIGTERM/SIGINT; an unrequested exit 0 is
        // still a clean shutdown, so stay stopped.
        if !bySignal && code == 0 {
            log.appendSystem("ShellyLanMan hat sich sauber beendet (Exit 0) — bleibt gestoppt")
            status = .stopped
            notifier.clear()
            restartAttempt = 0
            escalatedThisEpisode = false
            return
        }

        let reasonText = bySignal ? "durch Signal \(code) beendet" : "mit Exit-Code \(code) beendet"
        status = .crashed(reasonText)
        lastError = reasonText
        log.appendSystem("ShellyLanMan \(reasonText)")
        notifier.report(serverHealthy: false, detail: reasonText)

        guard settings.autoRestart else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = backoffSeconds[min(restartAttempt, backoffSeconds.count - 1)]
        restartAttempt += 1
        log.appendSystem("Automatischer Neustart in \(Int(delay)) s (Versuch \(restartAttempt))")
        if restartAttempt >= restartEscalateThreshold && !escalatedThisEpisode {
            escalatedThisEpisode = true
            notifier.oneShot(
                title: "ShellyLanMan: Auto-Restart gescheitert",
                body: "Der Dienst ließ sich nach \(restartAttempt) Versuchen nicht stabil starten und wird weiter versucht.")
        }
        let work = DispatchWorkItem { [weak self] in self?.start() }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
