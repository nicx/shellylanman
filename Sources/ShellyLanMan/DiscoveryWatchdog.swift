import Foundation

/// The server starts its mDNS browser once and does not retry: when the Mac has no
/// usable network interface at that moment (right after boot or login, before the
/// VLAN is up) the log shows "mdns: no usable network interface" and discovery stays
/// off until someone triggers a manual scan. All devices then show as offline or
/// archived. This watchdog notices `mdnsActive == false` in the scan state and
/// restarts the server once a usable interface exists.
@MainActor
final class DiscoveryWatchdog {
    private let settings: AppSettings
    private let server: ServerController
    private let log: LogStore
    private var loop: Task<Void, Never>?
    private var lastRestart = Date.distantPast
    /// Minimum gap between watchdog restarts, so a persistent problem cannot cause a restart loop.
    private let minGap: TimeInterval = 300

    init(settings: AppSettings, server: ServerController, log: LogStore) {
        self.settings = settings
        self.server = server
        self.log = log
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.tick()
            }
        }
    }

    private struct ScanState: Decodable {
        let mode: String
        let mdnsActive: Bool
        let mdnsError: String?
    }

    private func tick() async {
        guard server.status == .running,
              let up = server.startedAt, Date().timeIntervalSince(up) > 45,
              Date().timeIntervalSince(lastRestart) > minGap,
              NetworkProbe.hasUsableInterface() else { return }
        guard let scan = await fetchScan(), scan.mode == "full" || scan.mode == "local",
              !scan.mdnsActive else { return }
        lastRestart = Date()
        log.appendSystem("mDNS-Suche inaktiv (\(scan.mdnsError ?? "ohne Fehlermeldung")), Netzwerk ist da — starte ShellyLanMan neu")
        server.restart()
    }

    private func fetchScan() async -> ScanState? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.port)/api/v1/scan")!)
        request.timeoutInterval = 10
        if let token = TokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }
}
