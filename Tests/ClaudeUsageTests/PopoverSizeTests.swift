import AppKit
import SwiftUI
import Testing
@testable import ClaudeUsage
@testable import UsageCore

/// MenuBarExtra(.window) sizes its window from the content's minimum size. A popover whose minimum height is only its
/// header and footer (a ScrollView's minimum height is zero) opens as a strip with nothing in between.
@MainActor
struct PopoverSizeTests {
    @Test(arguments: [Route.usage, .settings, .addAccount])
    func everyRouteOpensAtFullHeight(route: Route) throws {
        let fixture = try PopoverFixture(route: route)
        #expect(fixture.minimumSize.width == 340)
        #expect(fixture.minimumSize.height >= 500)
    }

    @Test func theUsageScreenWithoutAnAccountOpensAtFullHeight() throws {
        let fixture = try PopoverFixture(route: .usage, accounts: [])
        #expect(fixture.minimumSize.height >= 500)
    }

    @Test func thePopoverFitsAShortScreen() {
        #expect(Popover.height(visibleScreenHeight: nil) == 600)
        #expect(Popover.height(visibleScreenHeight: 1_080) == 600)
        #expect(Popover.height(visibleScreenHeight: 560) == 520)
    }
}

/// A model filled by hand: it never polls, and its files live in a scratch folder deleted with the fixture.
@MainActor
final class PopoverFixture {
    let model: AppModel
    private let dir: URL

    init(route: Route, accounts: [Account] = [PopoverFixture.account]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cu-ui-tests-\(UUID().uuidString)",
                                                                             isDirectory: true)
        let paths = Paths(home: dir, appSupport: dir.appendingPathComponent("support", isDirectory: true))
        try paths.ensureAppSupport()
        let env = CoreEnvironment.make(paths: paths, secrets: InMemorySecretStore(), http: OfflineHTTP(),
                                       now: SystemDateProvider(),
                                       terminalItem: TerminalKeychainItem(service: "test", account: "test"),
                                       readOnly: true)
        model = AppModel(env: env, readOnly: true, poster: NoopNotificationPoster())
        model.accounts = accounts
        model.terminalID = accounts.first?.id
        for account in accounts { model.states[account.id] = Self.state }
        model.route = route
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// What MenuBarExtra asks for: the smallest size the content accepts at the popover's width.
    var minimumSize: NSSize {
        NSHostingController(rootView: RootView().environment(model)).sizeThatFits(in: NSSize(width: 340, height: 0))
    }

    static let account = Account(id: "acc-w:org-w", accountUuid: "acc-w", organizationUuid: "org-w",
                                 email: "work@example.com", displayName: nil, organizationName: nil,
                                 organizationType: "max", rateLimitTier: "default_claude_max_20x",
                                 subscriptionType: "max", label: "Work", colorIndex: 0, addedAt: Date(), status: .ok,
                                 oauthAccountJSON: nil)

    static var state: AccountRefreshState {
        let now = Date()
        let session = UsageLimit(id: "session", kind: "session", title: "Session · 5h", percent: 25, severity: nil,
                                 resetsAt: now.addingTimeInterval(7_200), windowSeconds: UsageLimit.sessionSeconds,
                                 isActive: true, modelName: nil)
        return AccountRefreshState(snapshot: UsageSnapshot(limits: [session], surfaces: [], extraUsageEnabled: false,
                                                           fetchedAt: now),
                                   lastSuccess: now, status: .ok, consecutiveRateLimits: 0, backoffUntil: nil,
                                   isStale: false)
    }
}

/// Never reaches the network.
struct OfflineHTTP: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}
