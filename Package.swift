// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexQuota",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "CodexQuota", targets: ["CodexQuotaApp"]),
        .executable(name: "CodexQuotaLauncher", targets: ["CodexQuotaLauncher"]),
        .executable(name: "CodexQuotaTests", targets: ["CodexQuotaTests"]),
    ],
    targets: [
        .target(
            name: "CodexQuotaCore"
        ),
        .executableTarget(
            name: "CodexQuotaApp",
            dependencies: ["CodexQuotaCore"]
        ),
        .executableTarget(
            name: "CodexQuotaLauncher"
        ),
        .executableTarget(
            name: "CodexQuotaTests",
            dependencies: ["CodexQuotaCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
