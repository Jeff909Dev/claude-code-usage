# Spike notes (Task 1)

- `CLAUDE_CONFIG_DIR=<dir> claude auth status --json` reports `configDirectory` exactly as the given string
  (no symlink resolution) and creates `<dir>/.claude.json` → the account file for a custom config dir is
  `<dir>/.claude.json`.
- Claude Code guards `.claude.json` with a lock **directory** `<file>.lock` (proper-lockfile style). Our writer
  takes the same lock (mkdir; stale after 10 s).
- Keychain service for a custom config dir = `Claude Code-credentials-` + first 8 hex of
  sha256(<dir string>), e.g. `/Users/dev/.claude` → `c6b08108` (checked against an existing item).
- Keychain item account attribute = the macOS user name (`NSUserName()`).
- Not verifiable without a human: how `claude auth login` behaves without a TTY and whether `--email` forces a
  fresh claude.ai session. Covered by the manual QA checklist (Task 17).

# Task 2 note

- `security -i` with a quoted service name (including spaces) and `-X <hex>` works for `add-generic-password -U`,
  so values whose command fits one line stay out of `ps`.
- `security -i` works only for lines <= 4096 bytes (longer lines are silently truncated, and the truncated hex is
  still written). Commands over 4000 bytes (the real Claude Code item is ~10 KB) therefore use argv
  `add-generic-password ... -X <hex>`, visible to same-user `ps` for the duration of the call.
- `find-generic-password -w` prints hex when the value contains any non-printable byte (non-ASCII, tab, newline);
  `SecurityCLIStore.read` hex-decodes such output, and `CredentialsJSON.merging` emits ASCII-only JSON.

## Real-data check (Task 13)

Release build, 2026-10-02, against this Mac's real data with `--read-only` (no token refreshed or written; the
account list and index lived in `$TMPDIR/ClaudeUsage-read-only`, `~/Library/Application Support/ClaudeUsage` was
not created). Dollar amounts and account details are left out on purpose.

- `status`: the terminal account is listed as `Max 20x  ● terminal  [ok]` with the rows `Session · 5h`,
  `Week · all models`, `Week · Fable`; 1.1 s wall. No token in the output.
- `stats --unknown-models`, first run: indexed every local transcript file (several GB) in about 73 s. Unknown
  models: none.
- `scripts/verify_spend.py` (10 s) vs the CLI's `today`: identical to the cent (0.00 % apart); the script gave the
  same figure right before and right after the CLI run.
- `stats`, second run: index refresh 0.4 s (0.8 s wall).
