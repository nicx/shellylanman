// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShellyLanMan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ShellyLanMan",
            path: "Sources/ShellyLanMan"
        )
    ],
    swiftLanguageModes: [.v5]
)
