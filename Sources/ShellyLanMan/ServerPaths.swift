import Foundation

/// Where the ShellyLanMan server binary lives and where it keeps its data and logs.
///
/// Two binaries can exist: the one built into the app bundle, and a newer one the app
/// built itself through "update server" (`ServerUpdater`). The newer one wins.
enum ServerPaths {
    /// The Go server binary built by `Scripts/build-server.sh` and copied into
    /// `Contents/Helpers/` by `make-app.sh`. Not in `Contents/MacOS/`: the
    /// default case-insensitive volume would clash it with the app executable.
    /// `SHELLYLANMAN_BINARY` overrides it for `swift run`.
    static var bundledBinaryURL: URL {
        if let override = ProcessInfo.processInfo.environment["SHELLYLANMAN_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shellylanman")
    }

    /// Version the bundled binary was built from, "1.0.0 (a30ed00)" (Info.plist, set by `make-app.sh`).
    static var bundledVersionText: String? {
        Bundle.main.object(forInfoDictionaryKey: "ShellyLanManServerVersion") as? String
    }

    /// Servers the app built itself: `<root>/<version>/shellylanman`, current one named in `<root>/current`.
    static var installedRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShellyLanMan-Server", isDirectory: true)
    }

    /// Working folder of the update build (toolchain, upstream sources): large, safe to delete.
    static var buildRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShellyLanManBuild", isDirectory: true)
    }

    /// The installed server, if one exists and is intact. `current` holds "version\ncommit".
    static var installed: (version: String, commit: String, url: URL)? {
        guard let text = try? String(contentsOf: installedRoot.appendingPathComponent("current"), encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let version = lines.first, !version.isEmpty else { return nil }
        let url = installedRoot.appendingPathComponent(version).appendingPathComponent("shellylanman")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return (version, lines.count > 1 ? lines[1] : "", url)
    }

    /// Dotted version number of the bundled binary ("1.0.0").
    static var bundledVersion: String? {
        bundledVersionText?.split(separator: " ").first.map(String.init)
    }

    /// The binary that gets started: the installed one when it is newer than the bundled one.
    static var binaryURL: URL {
        if let installed, let bundled = bundledVersion, AppSettings.isNewer(installed.version, than: bundled) {
            return installed.url
        }
        if let installed, bundledVersion == nil { return installed.url }
        return bundledBinaryURL
    }

    /// Version of the binary that gets started, e.g. "1.1.0".
    static var activeVersion: String? {
        binaryURL == bundledBinaryURL ? bundledVersion : installed?.version
    }

    /// For the menu, settings and log: "1.1.0 (41a3765)".
    static var serverVersion: String? {
        if binaryURL != bundledBinaryURL, let installed {
            return installed.commit.isEmpty ? installed.version : "\(installed.version) (\(installed.commit))"
        }
        return bundledVersionText
    }

    /// Whether a command line belongs to one of our server binaries (orphan takeover).
    static func isOurBinary(command: String) -> Bool {
        command.hasPrefix(bundledBinaryURL.path) || command.hasPrefix(installedRoot.path)
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
