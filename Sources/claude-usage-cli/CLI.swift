import Foundation
import UsageCore

@main
enum CLI {
    enum CLIError: Error {
        /// The command writes credentials, which --read-only promises never to do.
        case notInReadOnly(String)
    }

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let readOnly = args.contains("--read-only")
        args.removeAll { $0 == "--read-only" }
        let command = args.first ?? "status"
        do {
            if readOnly, ["switch", "login"].contains(command) { throw CLIError.notInReadOnly(command) }
            let env = try CoreEnvironment.live(readOnly: readOnly)
            switch command {
            case "status": try await status(env)
            case "accounts": try accounts(env)
            case "stats": try await stats(env, index: try env.makeIndex(), showUnknown: args.contains("--unknown-models"))
            case "reindex": try await reindex(env)
            case "switch":
                guard args.count >= 2 else { usage() }
                let result = try env.switcher.switchTerminal(to: args[1])
                print("Terminal switched to \(result.toID) — new `claude` sessions use it.")
            case "login":
                let email = args.firstIndex(of: "--email").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                try await login(env, email: email)
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(message(for: error))\n".utf8))
            exit(1)
        }
    }

    /// Unknown commands and missing arguments end here: print the help and fail.
    static func usage() -> Never {
        print("""
        usage: claude-usage-cli [--read-only] <command>
          status                  limits of every account (default)
          accounts                list accounts and their ids
          stats [--unknown-models]  API-equivalent spend on this Mac
          reindex                 rebuild the transcript index (after editing pricing.json)
          switch <account-id>     point the terminal at another account
          login [--email <e>]     add an account through `claude auth login`
        --read-only never refreshes a token or writes a credential, and keeps the account list and index in a
        scratch copy; switch and login are not available with it.
        """)
        exit(2)
    }

    static func warn(_ text: String) {
        FileHandle.standardError.write(Data("warning: \(text)\n".utf8))
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s + " " : s + String(repeating: " ", count: width - s.count)
    }

    static func text(for status: AccountStatus) -> String {
        switch status {
        case .ok: "ok"
        case .needsSignIn: "needs sign-in"
        case .offline: "offline"
        case .rateLimited: "rate limited"
        case .waitingForClaudeCode: "waiting for Claude Code"
        }
    }

    /// An ok state without a snapshot was never fetched (the account was skipped), so it has no data either.
    static func text(for state: AccountRefreshState?) -> String {
        guard let state, state.snapshot != nil || state.status != .ok else { return "no data" }
        return text(for: state.status)
    }

    static func status(_ env: CoreEnvironment) async throws {
        let poll = try await Poller(api: env.api, credentials: env.credentials, now: env.now)
            .poll(store: env.store, terminal: env.terminalFile, force: true)
        if let problem = poll.terminalError { warn(problem) }
        if poll.accounts.isEmpty {
            print("No accounts yet: sign in with `claude`, or add one with `claude-usage-cli login`.")
        }
        let now = env.now.now()
        for account in poll.accounts {
            let state = poll.states[account.id]
            let tag = account.id == poll.terminalID ? "  ● terminal" : ""
            print("✻ \(account.label)  \(account.email)  \(account.plan)\(tag)  [\(text(for: state))]")
            for limit in state?.snapshot?.limits ?? [] {
                let pace = PaceCalculator.pace(for: limit, now: now)
                print("  " + pad(limit.title, 20) + pad(Format.percent(limit.percent), 6)
                      + pad(Format.resetText(for: limit, now: now, calendar: .current), 28)
                      + "⎿ " + Format.paceLine(pace, percent: limit.percent, calendar: .current))
            }
        }
    }

    static func accounts(_ env: CoreEnvironment) throws {
        do {
            try TerminalAccountImporter.importIfNeeded(store: env.store, terminal: env.terminalFile, now: env.now.now())
        } catch {
            warn("Couldn't list the terminal's account: \(error.localizedDescription)")
        }
        let terminalID = env.terminalAccountID()
        for account in try env.store.load() {
            print(pad(account.id, 76) + pad(account.label, 14) + pad(account.email, 32) + pad(account.plan, 14)
                  + (account.id == terminalID ? "● terminal" : text(for: account.status)))
        }
    }

    static func stats(_ env: CoreEnvironment, index: TranscriptIndex, showUnknown: Bool) async throws {
        let started = Date()
        let progress = try await index.refresh { p in
            FileHandle.standardError.write(Data("\rindexing \(p.filesDone)/\(p.filesTotal)".utf8))
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        FileHandle.standardError.write(Data("\rindexed \(progress.filesTotal) files in \(seconds)s\n".utf8))
        let s = try await index.stats(now: env.now.now(), calendar: .current)
        print("today \(Format.money(micros: s.todayMicros))  ·  7 days \(Format.money(micros: s.last7dMicros))  ·  30 days \(Format.money(micros: s.last30dMicros))")
        print("\(Format.tokens(s.todayTokens)) tok · cache hit \(Int((s.cacheHitRate * 100).rounded()))% · \(s.todayMessages) msgs · \(s.todaySessions) sessions")
        print("model mix: " + s.modelMix.map { "\($0.family) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: " · "))
        for project in s.topProjects { print("  " + pad(project.project, 40) + Format.money(micros: project.costMicros)) }
        let peak = max(s.hourly.map(\.costMicros).max() ?? 0, 1)
        let bars = Array("▁▂▃▄▅▆▇█")
        print("last 24h " + String(s.hourly.map { bars[Int(Double($0.costMicros) / Double(peak) * 7)] }))
        if showUnknown {
            let unknown = try await index.unknownModels()
            print("unknown models: " + (unknown.isEmpty ? "none" : unknown.joined(separator: ", ")))
        }
    }

    static func reindex(_ env: CoreEnvironment) async throws {
        let index = try env.makeIndex()
        try await index.reset()
        try await stats(env, index: index, showUnknown: true)
    }

    static func login(_ env: CoreEnvironment, email: String?) async throws {
        guard let claude = env.locateClaude(customPath: nil) else { throw LoginError.couldNotLaunch }
        print("Finish signing in in your browser…")
        let account = try await env.makeLoginFlow(claude: claude).addAccount(method: email.map(LoginMethod.email) ?? .google)
        print("✓ Added \(account.email) · \(account.plan)")
    }

    /// Errors carry no secrets, so anything unrecognised is shown as is.
    static func message(for error: any Error) -> String {
        switch error {
        case CLIError.notInReadOnly(let command):
            "`\(command)` writes credentials; run it without --read-only"
        case SwitchError.unknownAccount: "no account with that id (see `claude-usage-cli accounts`)"
        case SwitchError.missingCredentials: "no saved login for that account; add it again with `claude-usage-cli login`"
        case SwitchError.alreadyActive: "the terminal already uses that account"
        case SwitchError.needsSignIn: "that account must sign in again first (`claude-usage-cli login --email <e>`)"
        case SwitchError.inconsistentTerminal:
            "Claude Code's Keychain item holds another listed account's login; the terminal was not switched"
        case SwitchError.unknownTerminalOwner:
            "Claude Code's Keychain item holds a login that ~/.claude.json doesn't name; the terminal was not switched"
        case SwitchError.terminalChanging:
            "Claude Code kept changing its login during the switch; the terminal was not switched, try again"
        case SwitchError.rollbackFailed(let underlying):
            "the switch failed and Claude Code's previous login couldn't be restored (\(underlying)); check "
                + "`claude auth status` and run `claude auth login` if the terminal's account is wrong"
        case LoginError.failed(let code): "sign-in failed (claude exited with \(code))"
        case LoginError.timedOut: "sign-in timed out"
        case LoginError.cancelled: "sign-in cancelled"
        case LoginError.noCredentials: "Claude Code didn't save a login; try again"
        case LoginError.couldNotLaunch: "couldn't start Claude Code; is `claude` installed and on your PATH?"
        default: String(describing: error)
        }
    }
}
