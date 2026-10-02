# Claude Usage — macOS menu bar app · Design

Date: 2026-10-01 · Status: draft for review · Repo: `Jeff909Dev/claude-code-usage`
Sibling project: Claude Account Switcher (Chrome extension) — its own repo and spec.
Visual reference: `prototypes/menubar.html` (open `prototypes/index.html`).

## 1. Intent

Jeff runs several Claude subscriptions (Max 20x, Max 5x, Pro, Team…). Today he can't see, at a glance, how much
of each account's limits is left, nor which account the terminal is using, and moving the terminal between
accounts is manual. The app lives in the macOS menu bar and answers three questions in one click:

1. Which account is the terminal (`claude`) using right now?
2. How much is left of each account's limits — 5-hour session, week (all models), week per model (Fable, …) —
   and am I burning faster than the window allows?
3. What am I "spending" (API-equivalent $) on this Mac, and which account should I use next?

Plus a Settings area to add accounts (Google or email magic link, via Claude's official sign-in) and switch
the terminal to any of them.

**Said by Jeff:** very simple, minimal, Claude Code look (same fonts/colors/components), compact, small type;
usage per account (week, day/session, Fable model); money spent and useful stats; settings with login per
account via Google or email magic link.
**Assumed (correct me):** macOS only; single user; read-only towards Anthropic except the official OAuth
endpoints; no cloud backend; Spanish/English UI copy can stay English like Claude Code (copy is trivial to change).

**Success criteria**
- Menu bar shows the terminal account's session % and tightest weekly % within 10 s of launch.
- Adding an account takes one click + the normal claude.ai sign-in; it then shows its limits.
- "Use in terminal" switches the account used by new `claude` sessions without breaking MCP logins or settings.
- Spend numbers match a manual recomputation from transcripts within 1 %.
- Idle CPU ≈ 0; first full transcript index of several GB finishes in < 2 min, later refreshes in < 1 s.

## 2. Verified facts this design relies on (checked on this Mac, Claude Code 2.1.287)

| Fact | Evidence |
|---|---|
| Terminal account = `~/.claude.json` → `oauthAccount` (`emailAddress`, `accountUuid`, `organizationUuid`, `organizationName`, `organizationType`, `organizationRateLimitTier`, …) | read locally |
| Terminal credentials = Keychain generic password, service `Claude Code-credentials`, account `$USER`, JSON `{claudeAiOauth:{accessToken, refreshToken, expiresAt, refreshTokenExpiresAt, scopes, subscriptionType, rateLimitTier}, mcpOAuth:{…}}` | `security find-generic-password` |
| With `CLAUDE_CONFIG_DIR=<dir>`, the service becomes `Claude Code-credentials-<first 8 hex of sha256(dir)>` | e.g. `/Users/dev/.claude` → `c6b08108`; checked against an existing item |
| `/usr/bin/security` can read these items without a Keychain prompt (items are created through it) | ran it |
| `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <accessToken>` + `anthropic-beta: oauth-2025-04-20` returns `five_hour`, `seven_day`, a generic `limits[]` (`kind` session / weekly_all / weekly_scoped, `percent`, `severity`, `resets_at`, `scope.model.display_name` e.g. "Fable", `is_active`), `seven_day_breakdown.rows[]` (Claude Code / Chats / Cowork / Other), `extra_usage`, `spend` | live call |
| `GET /api/oauth/profile` returns `account{uuid,email,display_name,has_claude_max,…}` and `organization{uuid,name,organization_type,rate_limit_tier,subscription_status,…}` | live call |
| `claude auth login [--email <email>]` runs the official OAuth sign-in in the browser (claude.ai → Google or email magic link); `claude auth status --json` reports email/org | `--help` |
| OAuth token endpoint `https://platform.claude.com/v1/oauth/token`, client id `9d1c250a-e61b-44d9-88ed-5944d1962f5e` | strings in the CLI binary |
| Access tokens live ~8 h; refresh tokens ~3 weeks (`refreshTokenExpiresAt`) | credential JSON |
| Transcripts: `~/.claude/projects/<project>/<session>.jsonl` (+ `subagents/`), assistant lines carry `message.model`, `message.usage` (`input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_5m_input_tokens`, `ephemeral_1h_input_tokens`), `timestamp`, `cwd`, `sessionId`; the same `message.id` repeats (×4 seen) | read locally |

## 3. Approaches considered

1. **Native SwiftUI `MenuBarExtra` + SwiftPM (recommended).** Tiny, no runtime, native Keychain/Process/
   notifications/launch-at-login. Core logic in a library with Swift Testing; a CLI target lets agents verify
   with real data without clicking UI. No Xcode project file (SwiftPM + a bundling script) → no merge conflicts.
2. Electron + `menubar`: reuses the HTML prototype directly, but ~150 MB and a Node runtime idling in the menu bar.
3. Tauri: reuses HTML, small, but needs Rust (not installed) and a second language for Keychain/Process glue.

Chosen: **1**. The HTML prototype is the visual spec; SwiftUI re-implements it.

## 4. Architecture

```
Package.swift
Sources/UsageCore/          # pure logic, no SwiftUI — fully unit-tested
  Paths.swift               # ~/.claude.json, ~/.claude/projects, App Support dir
  SecretStore.swift         # protocol + SecurityCLIStore (/usr/bin/security) + InMemoryStore (tests)
  Credentials.swift         # Codable OAuth creds; merge that replaces ONLY claudeAiOauth
  Accounts.swift            # Account model + AccountStore (accounts.json + secrets)
  TerminalAccount.swift     # read/write oauthAccount in ~/.claude.json (atomic, preserves other keys)
  UsageAPI.swift            # /api/oauth/usage + /api/oauth/profile, tolerant decoding
  TokenRefresher.swift      # refresh_token grant with ownership rules (§6)
  AccountSwitcher.swift     # "Use in terminal"
  LoginFlow.swift           # `claude auth login` in a temp CLAUDE_CONFIG_DIR, import, cleanup
  Pace.swift                # elapsed fraction, delta vs pace, projected 100 % time
  Recommender.swift         # best account now
  Pricing.swift + pricing.json
  TranscriptIndex.swift     # incremental JSONL → SQLite hourly buckets
  Stats.swift               # queries for the Usage view
  Poller.swift              # refresh loop, backoff, staleness
  Notifier.swift            # threshold-crossing logic (UI posts via UserNotifications)
Sources/ClaudeUsage/        # SwiftUI app (thin)
  App.swift                 # MenuBarExtra(.window), LSUIElement
  Theme.swift               # tokens mirrored from prototypes/tokens.css; cli/app/system styles
  UsageView.swift, LimitsSection.swift, StatsSection.swift, AccountChips.swift
  SettingsView.swift, AddAccountView.swift
Sources/claude-usage-cli/   # `claude-usage status|stats|accounts|switch|login` — same core, text output
Tests/UsageCoreTests/       # Swift Testing, fixtures in Tests/Fixtures
scripts/bundle.sh           # release build → build/Claude Usage.app (Info.plist, ad-hoc sign)
Makefile                    # build, test, app, run, install
```

Boundaries: `UsageCore` never imports SwiftUI/AppKit; everything with side effects (Keychain, filesystem,
network, process, clock) sits behind a small protocol so tests inject fakes. The app and the CLI are two thin
front-ends over the same `UsageCore`.

## 5. Data model

- `Account` — `id = "<accountUuid>:<organizationUuid>"`, `email`, `displayName`, `organizationName`,
  `plan` (derived: `subscriptionType` + `rateLimitTier` → "Max 20x", "Max 5x", "Pro", "Team · Premium"…),
  `label` (user-editable, default = org/email local part), `colorIndex`, `addedAt`, `status`
  (`ok` | `needsSignIn` | `offline` | `rateLimited`).
- Account list → `~/Library/Application Support/ClaudeUsage/accounts.json`.
- Account credentials (app-owned) → Keychain service `Claude Usage`, account = `Account.id`, value = the
  `claudeAiOauth` JSON, written via `/usr/bin/security` (avoids per-build Keychain prompts with ad-hoc signing).
- `UsageSnapshot` per account — `limits[]` (`kind`, `title`, `percent`, `resetsAt`, `windowSeconds`,
  `severity`, `isActive`), `surfaceBreakdown[]`, `extraUsage`, `fetchedAt`. Cached in memory + last value on disk
  for instant display at launch.

## 6. Credentials & token ownership (the subtle part)

Refresh tokens rotate: if two programs refresh the same token, one breaks. Rule: **every account has exactly one
owner of its refresh token.**

- The account currently in the terminal is owned by **Claude Code** (default Keychain item). The app reads it,
  calls the usage API with its access token, and refreshes it only if it is expired > 5 min (Claude Code is not
  using it). After a refresh it writes back **only** `claudeAiOauth`, keeping `mcpOAuth` and any other key.
  On `invalid_grant` it re-reads the item once (Claude Code may have refreshed it meanwhile) and retries.
- Every other account is owned by **the app** (`Claude Usage` Keychain item). The app refreshes it when the
  access token is within 10 min of `expiresAt`.
- Refresh failure with `invalid_grant` / expired refresh token → `needsSignIn` ("Sign in again" in UI).

**Use in terminal (switch A → B):**
1. Read the default item; if its `claudeAiOauth` belongs to A, save it into A's app-owned item (it may have been
   refreshed by Claude Code).
2. Write B's creds into the default item's `claudeAiOauth` (merge, keep `mcpOAuth`).
3. Update `oauthAccount` in `~/.claude.json` with B's profile fields (read-modify-write the latest file content,
   write to temp + rename, preserve every other key; abort if the file changed between read and rename and retry).
4. Ownership of B moves to Claude Code; A moves to the app.
5. UI: "Terminal switched to B — new `claude` sessions use it" (running sessions keep A until restarted).

## 7. Adding an account (Settings → Add account)

UI mirrors claude.ai: **Continue with Google** / email field + **Continue with email**. Both run Claude Code's
official login so we never handle passwords:

1. `tmp = AppSupport/login/<uuid>`; run `CLAUDE_CONFIG_DIR=tmp claude auth login` (Google) or
   `… claude auth login --email <email>` (email → claude.ai sends the magic link). The browser opens; the user
   finishes sign-in there.
2. On exit 0: read Keychain `Claude Code-credentials-<sha8(tmp)>` and `tmp/.claude.json` → `oauthAccount`;
   call `/api/oauth/profile` to confirm identity; store as app-owned account (dedupe by `Account.id`: re-login
   of an existing account just replaces its creds and clears `needsSignIn`).
3. Delete the temp Keychain item and `tmp`. Cancel = terminate the process + same cleanup. Timeout 10 min.
4. Note shown under the buttons: "Your browser authorizes whichever claude.ai account is signed in there —
   switch it first with the Claude Account Switcher extension."

`claude` binary discovery: `which claude` in a login shell, else `~/.local/bin/claude`, else
`~/.claude/local/claude`; Settings shows the path and lets the user pick it.

## 8. Usage view (what is shown)

Header: avatar · label · email · plan badge · `● terminal` tag on the terminal account · refresh (with "updated
Xm ago") · gear. Account chips under it switch which account the popover shows (view only).

**Limits** — one row per `limits[]` entry (order: session, weekly_all, weekly_scoped by model). Row = title,
percent, thin bar with a **pace marker** (elapsed fraction of the window), and a `⎿` line:
- `windowSeconds`: session 5 h, weekly 7 d; `start = resetsAt − window`.
- `elapsed = (now − start)/window`; `delta = percent − elapsed×100`.
- `|delta| ≤ 5` → "on pace"; `delta > 5` → "ahead of pace +N pts · 100 % ≈ <time>" where
  `t100 = start + (now − start) × 100/percent` (shown only if before `resetsAt`); `delta < −5` → "N pts under pace".
- Levels: < 70 normal, 70–89 warn, ≥ 90 critical.

**Best account now** — among accounts with status ok, the one whose tightest relevant limit (session, weekly_all,
and the weekly_scoped limit for the model the terminal uses most this week) has the most headroom; shown only
when it is not the terminal account. Button "Use in terminal".

**This Mac · API-equivalent spend** (from transcripts, labelled "estimated"):
- Today / 7 days / 30 days $, and "N× your plan" against the summed monthly price of the subscribed plans
  (plan prices in `pricing.json`, editable).
- Tokens today · cache hit % (`cache_read / (input + cache_read + cache_write)`) · messages · sessions.
- Last 24 h hourly bars (cost), model mix today (stacked bar), top 3 projects today (by cost; project = last two
  path components of `cwd`), 7-day surface breakdown from the API.

Menu bar title: `✻ 25% · 64%` (terminal account's session % · highest weekly %), monospaced digits; selectable
in Settings (Session / Week / Both / Icon only). Shows `✻ —` while loading and `✻ !` when the account needs sign-in.

## 9. Cost engine

Cost per assistant message = `in×p.in + out×p.out + cacheRead×p.cacheRead + cw5m×p.in×1.25 + cw1h×p.in×2.0`
(per MTok). `pricing.json` (bundled, overridable at `AppSupport/pricing.json`):

| model id prefix | input | output | cache read |
|---|---|---|---|
| claude-fable-5-1 | 10.00 | 50.00 | 0.25 |
| claude-fable-5 | 10.00 | 50.00 | 1.00 |
| claude-opus-5-5 | 4.00 | 20.00 | 0.20 |
| claude-opus-5, claude-opus-4-8/4-7/4-6 | 5.00 | 25.00 | 0.50 |
| claude-sonnet-5-5, claude-sonnet-5 | 2.00 | 10.00 | 0.20 |
| claude-sonnet-4-6 | 3.00 | 15.00 | 0.30 |
| claude-haiku-4-5 | 1.00 | 5.00 | 0.10 |

Longest-prefix match; unknown models cost $0 and are listed in the CLI's `stats --unknown-models`. `speed:"fast"`
lines are priced ×2 (Opus fast mode); `<synthetic>` model lines are skipped.

**Index:** SQLite (`AppSupport/index.sqlite`, system `SQLite3`). Tables: `files(path PK, size, mtime, offset)`,
`seen(message_id PK)`, `buckets(hour, model, project, input, output, cache_read, cw5m, cw1h, cost_micros,
messages, PRIMARY KEY(hour, model, project))`, `sessions(hour, session_id, PK both)`. Each refresh: enumerate
`projects/**/*.jsonl`, skip unchanged (size+mtime), read from stored `offset` to last complete newline, parse only
`"type":"assistant"` lines, `INSERT OR IGNORE` into `seen` and aggregate only first occurrences, all in one
transaction. Truncated/rotated file (size < offset) → reset its offset to 0 (dedupe protects totals). First run
streams files in a background task with progress ("indexing 1 200 / 3 000") and the view shows partial totals.

## 10. Refresh, errors, notifications

- Poll interval 1/5/15 min (default 5); manual refresh button; refresh on popover open if data > 60 s old.
- Per account independent: network error → keep last snapshot, mark "stale · offline"; HTTP 429 → exponential
  backoff (1→2→4→…15 min) with "rate-limited" note; 401 → refresh token once, then `needsSignIn`.
- Notifications (UserNotifications): crossing 80 % and 95 % per limit per window (once per `resetsAt`), and "limit
  reset" when a previously ≥ 95 % limit resets. Dedupe state persisted.
- Launch at login via `SMAppService.mainApp`.

## 11. Look & feel

Mirror `prototypes/tokens.css`: Claude Code CLI palette (claude orange `#d97757`, success `#4eba65`, warning, error
`#ff6b80`), claude.ai neutrals (dark `#262624`/`#1f1e1d`/`#30302e`, ivory `#faf9f5`), 0.5 px dividers, 12 px
padding, 11 px monospaced base (`SF Mono`) in **CLI style** (default), or system sans + mono numbers in **Claude
style**; **System** follows macOS appearance. Anthropic's own typefaces are proprietary, so they are not bundled.
Popover 340 pt wide, ≤ 640 pt tall, internal scroll.

## 12. Testing

- Swift Testing for all of `UsageCore`: usage JSON decoding (fixture captured from the live call, values
  scrubbed), unknown `kind`s, pace math (table-driven), pricing (per-model, cache multipliers, fast mode,
  unknown model), transcript indexing (fixtures: duplicates, partial last line, truncation, subagent files),
  `claudeAiOauth` merge keeps `mcpOAuth`, `oauthAccount` swap keeps all keys, sha8 service naming, token
  ownership decisions, recommender, notifier dedupe.
- The CLI (`swift run claude-usage-cli status`) is the end-to-end check against real data.
- UI: build + launch smoke test, plus a manual checklist (light/dark × CLI/Claude styles) in the plan.

## 13. Out of scope (v1)

Per-account spend attribution (transcripts don't record the account), Windows/Linux, API-key (Console) accounts,
sharing data off the machine, editing Claude Code settings, controlling claude.ai sessions in the browser
(that is the Chrome extension's job).

## 14. Risks & open checks (verified in plan task 1, before building on them)

- `claude auth login --email` pre-fills the email but the browser's current claude.ai session may still win →
  documented hint + extension; check whether a fresh session is forced.
- The usage endpoint is undocumented and may change → tolerant decoding, unknown limits rendered generically.
- Using Claude Code's public OAuth client id for refresh mirrors what Claude Code does; if it breaks, fallback =
  keep each non-terminal account in a persistent `CLAUDE_CONFIG_DIR` slot (its Keychain item named by §2's sha8
  rule) and let Claude Code refresh it by running a cheap `claude auth status` there (to be confirmed in the spike).
- `~/.claude.json` is rewritten often by running sessions → atomic compare-and-swap write with retry.

## 15. Distribution (requested by Jeff, 2026-10-01)

- Public GitHub repo `Jeff909Dev/claude-code-usage` (MIT). Before the first push: secret scan (no tokens, no real
  Keychain dumps; fixtures scrubbed).
- GitHub Release `v0.1.0` with asset `ClaudeUsage.zip` (unversioned name so the `latest/download` link is stable) (the ad-hoc-signed `Claude Usage.app`, built by
  `scripts/bundle.sh` + `scripts/release.sh`). Not notarized → install note: open it once, then System Settings ›
  Privacy & Security › Open Anyway (macOS 15 removed the right-click → Open bypass), or
  `xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"`.
- Landing page: `site/index.html` — one static page in the same Claude look (tokens.css), hero line, one real
  screenshot, **Download for macOS** (→ `https://github.com/Jeff909Dev/claude-code-usage/releases/latest/download/ClaudeUsage.zip`),
  3-step install, requirements (macOS 14+, Claude Code installed), link to GitHub. No framework, no analytics.
  Deployed to Vercel from `site/`.
