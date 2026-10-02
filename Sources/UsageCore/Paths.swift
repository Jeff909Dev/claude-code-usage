import Foundation

public struct Paths: Sendable, Equatable {
    public var home: URL
    public var appSupport: URL

    public init(home: URL, appSupport: URL) {
        self.home = home
        self.appSupport = appSupport
    }

    public static func live() -> Paths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
        return Paths(home: fm.homeDirectoryForCurrentUser, appSupport: support)
    }

    public func ensureAppSupport() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    public var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    public var claudeConfigDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var projectsDir: URL { claudeConfigDir.appendingPathComponent("projects", isDirectory: true) }
    public var accountsFile: URL { appSupport.appendingPathComponent("accounts.json") }
    public var indexDatabase: URL { appSupport.appendingPathComponent("index.sqlite") }
    public var pricingOverride: URL { appSupport.appendingPathComponent("pricing.json") }
    public var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }
    public var snapshotsCache: URL { appSupport.appendingPathComponent("snapshots.json") }
    public var notifierState: URL { appSupport.appendingPathComponent("notifier.json") }
    public var loginWorkRoot: URL { appSupport.appendingPathComponent("login", isDirectory: true) }
}
