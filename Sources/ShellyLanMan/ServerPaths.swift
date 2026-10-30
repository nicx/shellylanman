import Foundation

/// Where the bundled ShellyLanMan server binary lives and where it keeps its
/// data and logs.
enum ServerPaths {
    /// The Go server binary, built by `Scripts/build-server.sh` and copied into
    /// `Contents/Helpers/` by `make-app.sh`. Not in `Contents/MacOS/`: the
    /// default case-insensitive volume would clash it with the app executable.
    /// `SHELLYLANMAN_BINARY` overrides it for `swift run`.
    static var binaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SHELLYLANMAN_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/shellylanman")
    }

    /// Upstream version the bundled binary was built from (written into
    /// Info.plist by `make-app.sh`).
    static var serverVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "ShellyLanManServerVersion") as? String
    }

    /// `SHELLYLANMAN_DATA`: settings.json, archive.json, backups, firmware cache.
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShellyLanMan", isDirectory: true)
    }

    static var logsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ShellyLanMan", isDirectory: true)
    }

    static func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw NSError(domain: "ShellyLanMan", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Server-Binary fehlt: \(binaryURL.path)"
            ])
        }
    }
}
