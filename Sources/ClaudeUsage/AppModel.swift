import AppKit
import Observation
import SwiftUI
import UsageCore

enum Route: Equatable {
    case usage, settings, addAccount
}

enum AddAccountState: Equatable {
    case idle
    case waiting(LoginMethod)
    case success(email: String, plan: String)
    case failed(String)
}

@MainActor
@Observable
final class AppModel {
    static let readOnlyNote = "Read-only mode — switching, adding, renaming and removing accounts are off"

    let env: CoreEnvironment
    /// Started with --read-only: tokens are never refreshed, the app's files live in a scratch folder, and nothing
    /// that writes a login is offered.
    let readOnly: Bool
    @ObservationIgnored private let poster: any NotificationPosting
    @ObservationIgnored private let coordinator: RefreshCoordinator
    @ObservationIgnored private var index: TranscriptIndex?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var locating: Task<URL?, Never>?
    @ObservationIgnored private var notifierState: NotifierState
    @ObservationIgnored private var appliedRound = 0
    @ObservationIgnored private var refreshesInFlight = 0

    var accounts: [Account] = []
    var states: [String: AccountRefreshState]
    var terminalID: String?
    /// Why the last poll couldn't read ~/.claude.json or the account list; nil when it could.
    var pollError: String?
    var selectedID: String?
    var stats = SpendStats.empty
    var indexProgress: IndexProgress?
    var preferredModel: String?
    var route = Route.usage
    var addState = AddAccountState.idle
    var addPrefillEmail = ""
    var toast: String?
    var isRefreshing = false
    var isSwitching = false
    var isRemoving = false
    /// A switch or a removal is under way; the UI disables both meanwhile, and both ignore a second request.
    var isChangingAccounts: Bool { isSwitching || isRemoving }
    /// The claude binary "Add account" runs, found off the main thread (a login shell can take seconds).
    var claudeLocation: URL?
    /// A lookup of the claude binary is running; `claudeLocation` may be about to change.
    var isLocatingClaude = false
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            do { try settings.save(to: env.paths.settingsFile) } catch {
                showToast("Couldn't save settings: \(StatusText.message(for: error))")
            }
            if oldValue.refreshInterval != settings.refreshInterval { restartLoop() }
            if oldValue.claudePath != settings.claudePath { locateClaude(sweepFirst: false) }
        }
    }

    init(env: CoreEnvironment, readOnly: Bool, poster: any NotificationPosting) {
        self.env = env
        self.readOnly = readOnly
        self.poster = poster
        let cached = StateCache.load(from: env.paths.snapshotsCache)
        self.states = cached
        self.coordinator = RefreshCoordinator(
            poller: Poller(api: env.api, credentials: env.credentials, now: env.now, initial: cached),
            store: env.store, terminal: env.terminalFile, cacheURL: env.paths.snapshotsCache)
        self.settings = AppSettings.load(from: env.paths.settingsFile)
        self.notifierState = NotifierState.load(from: env.paths.notifierState)
    }

    // MARK: Derived

    func account(id: String) -> Account? { accounts.first { $0.id == id } }
    func state(for id: String) -> AccountRefreshState? { states[id] }
    var terminalAccount: Account? { terminalID.flatMap(account(id:)) }
    var displayedAccount: Account? { selectedID.flatMap(account(id:)) ?? terminalAccount ?? accounts.first }
    var displayedSnapshot: UsageSnapshot? { displayedAccount.flatMap { states[$0.id]?.snapshot } }

    var menuBarTitle: String {
        let state = terminalID.flatMap { states[$0] }
        return MenuBarTitle.text(mode: settings.menuBarMode, snapshot: state?.snapshot, status: state?.status)
    }

    var bestAccountID: String? {
        Recommender.best(accounts: accounts, states: states, terminalID: terminalID, preferredModel: preferredModel,
                         now: env.now.now())
    }

    var monthlyPlanTotal: Double { env.pricing.monthlyTotal(for: accounts.map(\.plan)) }
    var spendSummary: SpendSummary { SpendSummary.from(stats, monthlyPlanTotal: monthlyPlanTotal) }

    /// "week 12% · Fable 20%"
    func headroomLine(for account: Account) -> String {
        guard let snapshot = states[account.id]?.snapshot else { return "" }
        var parts: [String] = []
        if let week = snapshot.limits.first(where: { $0.kind == "weekly_all" }) { parts.append("week \(Format.percent(week.percent))") }
        if let model = preferredModel,
           let scoped = snapshot.limits.first(where: { $0.kind == "weekly_scoped" && $0.modelName?.caseInsensitiveCompare(model) == .orderedSame }) {
            parts.append("\(model) \(Format.percent(scoped.percent))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Lifecycle

    func start() {
        NSApplication.shared.setActivationPolicy(.accessory)
        // Last known numbers right away; the first round lists the terminal's account and reports unreadable files.
        accounts = (try? env.store.load()) ?? []
        terminalID = env.terminalAccountID()
        locateClaude(sweepFirst: !readOnly)
        restartLoop()
    }

    /// The polling loop runs until it is replaced (a new interval) or the model goes away; it holds the model only
    /// during a cycle, never while it sleeps. Rounds run in the coordinator, so cancelling the loop never cuts one short.
    private func restartLoop() {
        loop?.cancel()
        let interval = settings.refreshInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.pollCycle()
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// A round, plus an indexing pass that may outlast it.
    private func pollCycle() async {
        Task { await refreshStats() }
        await refreshNow(force: false)
    }

    /// Finds the claude binary off the main thread. At launch it first removes what a crashed sign-in left behind;
    /// every lookup waits for the one before, so no sign-in can start while that sweep runs.
    private func locateClaude(sweepFirst: Bool) {
        let env = self.env, customPath = settings.claudePath, previous = locating
        let task = Task.detached { () -> URL? in
            _ = await previous?.value
            if sweepFirst { env.sweepLoginLeftovers() }
            return env.locateClaude(customPath: customPath)
        }
        locating = task
        isLocatingClaude = true
        Task {
            let location = await task.value
            if locating == task {
                claudeLocation = location
                isLocatingClaude = false
            }
        }
    }

    func popoverOpened() {
        let last = terminalID.flatMap { states[$0]?.lastSuccess }
        guard Poller.shouldRefreshOnOpen(lastSuccess: last, now: env.now.now()) else { return }
        Task { await refreshNow(force: false) }
    }

    /// A forced refresh asked for while an unforced round runs gets a forced round of its own after it.
    func refreshNow(force: Bool) async {
        refreshesInFlight += 1
        isRefreshing = true
        defer {
            refreshesInFlight -= 1
            isRefreshing = refreshesInFlight > 0
        }
        do {
            apply(try await coordinator.poll(force: force))
        } catch {
            pollError = "Couldn't read the account list: \(StatusText.message(for: error))"
        }
    }

    private func apply(_ round: PollRound) {
        guard round.number > appliedRound else { return }
        appliedRound = round.number
        accounts = round.result.accounts
        terminalID = round.result.terminalID
        states = round.result.states
        pollError = round.result.terminalError
        notify()
    }

    /// Indexes transcripts in batches so the first multi-GB run shows partial totals and never blocks the UI. A call
    /// made while one runs waits for it.
    func refreshStats() async {
        if let statsTask { return await statsTask.value }
        let task = Task { await indexTranscripts() }
        statsTask = task
        await task.value
        statsTask = nil
    }

    private func indexTranscripts() async {
        do {
            if index == nil { index = try env.makeIndex() }
            guard let index else { return }
            while true {
                let progress = try await index.refresh(limit: 200)
                indexProgress = progress.isComplete ? nil : progress
                stats = try await index.stats(now: env.now.now(), calendar: .current)
                if progress.isComplete { break }
            }
            preferredModel = try await index.topModelFamily(since: env.now.now().addingTimeInterval(-7 * 86_400))
        } catch {
            indexProgress = nil
            showToast("Spend stats unavailable: \(StatusText.message(for: error))")
        }
    }

    private func notify() {
        let now = env.now.now()
        let notifier = Notifier(thresholds: settings.thresholds, notifyOnReset: settings.notifyOnReset)
        let before = notifierState
        var events: [NotificationEvent] = []
        for account in accounts {
            guard let state = states[account.id], state.status == .ok, !state.isStale,
                  let snapshot = state.snapshot else { continue }
            events += notifier.evaluate(accountID: account.id, label: account.label, snapshot: snapshot,
                                        state: &notifierState, now: now)
        }
        if notifierState != before { try? notifierState.save(to: env.paths.notifierState) }
        if !events.isEmpty { poster.post(events) }
    }

    // MARK: Actions

    /// Runs off the main actor (Keychain and the ~/.claude.json lock can block for seconds) and never alongside a
    /// poll round, so no refresh rotates the target's token while it is being copied.
    func useInTerminal(_ id: String) {
        guard !readOnly else { return showToast(Self.readOnlyNote) }
        guard !isChangingAccounts else { return }
        isSwitching = true
        let switcher = env.switcher
        Task {
            do {
                let result = try await coordinator.exclusive { try switcher.switchTerminal(to: id) }
                isSwitching = false
                terminalID = result.toID
                showToast("✻ Terminal switched to \(account(id: result.toID)?.label ?? "account") — new `claude` sessions use it")
                await refreshNow(force: true)
            } catch {
                isSwitching = false
                showToast(StatusText.switchFailure(error))
            }
        }
    }

    func addAccount(_ method: LoginMethod) {
        guard !readOnly else {
            addState = .failed(Self.readOnlyNote)
            return
        }
        guard loginTask == nil else { return }
        addState = .waiting(method)
        let env = self.env, locating = self.locating
        loginTask = Task {
            let outcome: Result<Account, any Error>
            do {
                guard let claude = await locating?.value else { throw LoginError.couldNotLaunch }
                outcome = .success(try await env.makeLoginFlow(claude: claude).addAccount(method: method))
            } catch {
                outcome = .failure(error)
            }
            // A cancelled sign-in was already cleared by cancelAddAccount(), and another may have started since.
            guard !Task.isCancelled else { return }
            loginTask = nil
            switch outcome {
            case .success(let account):
                addState = .success(email: account.email, plan: account.plan)
                await refreshNow(force: true)
                try? await Task.sleep(for: .seconds(1.5))
                if case .success = addState {
                    addState = .idle
                    route = .settings
                }
            case .failure(LoginError.cancelled):
                addState = .idle
            case .failure(let error):
                addState = .failed(StatusText.signInFailure(error))
            }
        }
    }

    func cancelAddAccount() {
        loginTask?.cancel()
        loginTask = nil
        addState = .idle
    }

    func signInAgain(_ account: Account) {
        addPrefillEmail = account.email
        addState = .idle
        route = .addAccount
    }

    /// Off in read-only mode: the account list there is a throw-away copy.
    func rename(_ id: String, to name: String) {
        guard !readOnly else { return showToast(Self.readOnlyNote) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try env.store.update(id: id) { $0.label = trimmed } } catch {
            showToast("Couldn't rename: \(StatusText.message(for: error))")
        }
        accounts = (try? env.store.load()) ?? accounts
    }

    /// Deleting the Keychain item blocks, and must not race a refresh writing that item back. The terminal's account
    /// is checked again inside, since a switch queued before this one may have moved the terminal to it.
    func remove(_ id: String) {
        guard !readOnly else { return showToast(Self.readOnlyNote) }
        guard !isChangingAccounts else { return }
        guard id != terminalID else { return showToast(StatusText.message(for: RemoveAccountError.inTerminal)) }
        isRemoving = true
        let env = self.env
        Task {
            do {
                try await coordinator.exclusive { try env.removeAccount(id: id) }
                states[id] = nil
                if selectedID == id { selectedID = nil }
            } catch {
                showToast("Couldn't remove the account: \(StatusText.message(for: error))")
            }
            isRemoving = false
            accounts = (try? env.store.load()) ?? accounts
        }
    }

    /// Longer messages stay up longer.
    func showToast(_ text: String) {
        toast = text
        let seconds = max(3, Double(text.count) / 15)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if toast == text { toast = nil }
        }
    }

    func quit() { NSApplication.shared.terminate(nil) }
}
