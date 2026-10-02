// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"]),
        .executable(name: "claude-usage-cli", targets: ["claude-usage-cli"]),
    ],
    targets: [
        .target(name: "UsageCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "ClaudeUsage", dependencies: ["UsageCore"]),
        .executableTarget(name: "claude-usage-cli", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
        .testTarget(name: "ClaudeUsageTests", dependencies: ["ClaudeUsage", "UsageCore"]),
    ]
)
