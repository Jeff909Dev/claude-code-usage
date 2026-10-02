# ✻ Claude Usage

A tiny macOS menu bar app that shows every Claude account's limits — 5-hour session, week, week per model
(Fable, …) — whether you are burning faster than the window allows, and what your Claude Code use on this Mac
would cost at API prices. Add accounts with Claude Code's own login (Google or email magic link) and switch the
terminal between them in one click.

Unofficial; not affiliated with Anthropic.

## Install

    curl -fsSL https://claude-code-usage.vercel.app/install.sh | bash

It downloads the latest release, puts `Claude Usage.app` in `/Applications` (quitting and replacing an older copy)
and opens it. The app isn't notarized yet, but macOS doesn't quarantine what curl downloads, so it opens without the
**Open Anyway** step. The script is [`scripts/install.sh`](scripts/install.sh); the site serves a copy of it.

Or by hand:

1. Download `ClaudeUsage.zip` from the latest release and unzip it.
2. Move `Claude Usage.app` to `/Applications`.
3. First launch: open it once, then click **Open Anyway** in System Settings › Privacy & Security. Or, before
   opening it, run `xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"`.

Requires macOS 14+ and Claude Code installed (`claude` on your PATH).

## Build from source

    make test          # swift test
    make test-install  # scripts/install.sh against local zips, into a temp folder (never /Applications)
    make app           # build/Claude Usage.app
    make run           # build and open it
    make install       # build and copy it to /Applications (quit the running app first)
    make cli ARGS="--read-only status"

## How it works

- Limits come from the same endpoint Claude Code's `/usage` uses, called with each account's OAuth token.
- The terminal's account is `~/.claude.json` → `oauthAccount` plus the `Claude Code-credentials` Keychain item.
  "Use in terminal" swaps only those (MCP logins and settings are kept).
- Claude Code owns the terminal account's token. The app refreshes it only after it has been expired for more
  than 5 minutes (Claude Code is not using it), and then writes back only `claudeAiOauth` in that item
  (`mcpOAuth` and every other key are kept).
- Other accounts' tokens live in your Keychain under "Claude Usage". Nothing leaves your Mac except calls to
  Anthropic's API.
- Keychain writes go through `/usr/bin/security`. Values up to about 2 KB (they are hex-encoded) are passed on its stdin; larger ones
  (Claude Code's item with MCP logins can be ~10 KB) are passed in its arguments for the moment of the call,
  where another process running as your user could see them with `ps`.
- Spend is estimated from `~/.claude/projects/**/*.jsonl` with public API prices (`pricing.json` in
  `~/Library/Application Support/ClaudeUsage/` overrides them; after editing it, run `make cli ARGS="reindex"`
  from a checkout of this repo).

## Manual QA checklist (before each release)

Run these from the installed app in `/Applications` unless noted. Use accounts you are happy to switch: try
**Use in terminal** first with a disposable account (one you can sign in to again), before your main one. If the
terminal ends up signed out or on the wrong account, run `claude auth login` to recover.

### Look and menu bar

- [ ] Light and dark appearance × CLI and Claude themes: popover matches `prototypes/menubar.html`.
- [ ] Menu bar title shows `✻ session% · week%` within 10 s of launch; each "Menu bar shows" option works, and
      the title updates when the numbers change.
- [ ] Settings → Appearance **System** after Dark/Light: colors re-resolve to the current system appearance.

### Refresh and numbers

- [ ] Refresh-on-open fires on every popover open, not only the first (watch "updated …" reset each time).
- [ ] Compare the percentages with Claude Code's `/usage` for the terminal account: they agree.
- [ ] `python3 scripts/verify_spend.py` and the popover's "today" agree within 1 %.

### Adding accounts (real login; never on an account you can't re-add)

- [ ] **Continue with Google**: the browser opens, after sign-in the account appears with its limits. The app
      launches `claude auth login` without a TTY (stdin is `/dev/null`), so this must work with no terminal.
- [ ] **Continue with email**: `--email` magic link arrives, login completes, account appears.
- [ ] The temp Keychain item is named like Claude Code's own (`Claude Code-credentials-<sha8 of the temp
      CLAUDE_CONFIG_DIR>`): the account imports, and no leftover remains. Compare
      `security dump-keychain | grep -c 'Claude Code-credentials-'` before and after: unchanged.
- [ ] Cancel during "Waiting for sign-in…": no leftover folder in `~/Library/Application Support/ClaudeUsage/login/`
      and no `Claude Code-credentials-…` item for it (same count check).

### Switching the terminal

- [ ] **Use in terminal** on another account, then in a new terminal: `claude auth status --json` shows that
      email; `/mcp` still lists your authenticated MCP servers; switching back restores the first account.
- [ ] A `claude` session started BEFORE the switch: note (observe and report) whether it keeps using or refreshes
      the old account, and whether that writes the old token back to the `Claude Code-credentials` item or
      `~/.claude.json`.

### Refreshing the terminal's token

- [ ] Leave a `claude` session open and idle until its access token has been expired > 5 min and the app has
      refreshed it (watch the `Claude Code-credentials` item's modification date:
      `security find-generic-password -s "Claude Code-credentials" | grep mdat`); then send a prompt in that old
      session — does it recover, ask to log in, or write an old token back? Note the result.

### Account row actions

- [ ] Hover row actions appear in the real popover.
- [ ] Keyboard (Tab with **Full Keyboard Access** on in System Settings → Keyboard) and VoiceOver reach
      **Use in terminal**, **Rename** and **Remove**.
- [ ] Remove shows a confirmation; confirming removes the account and its "Claude Usage" Keychain item is gone.

### Settings

- [ ] **Choose…** opens an NSOpenPanel for the `claude` binary; the chosen path is used and shown.
- [ ] **Launch at login** toggle works from `/Applications` (System Settings → General → Login Items lists
      "Claude Usage").

### Notifications

- [ ] The permission prompt appears once (first launch only).
- [ ] With an account above 80 %, one notification appears, once per window; the same for 95 %.
- [ ] A reset notification appears when a window resets.

### Safety and distribution

- [ ] Read-only smoke: `"/Applications/Claude Usage.app/Contents/MacOS/ClaudeUsage" --read-only` writes nothing
      to `~/Library/Application Support/ClaudeUsage` (compare `find` + `stat` listings before and after).
- [ ] Gatekeeper first launch from a downloaded zip: open once, then System Settings › Privacy & Security →
      **Open Anyway**; or `xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"` before opening.
- [ ] After publishing the release and the site: `curl -fsSL https://claude-code-usage.vercel.app/install.sh | bash`
      installs the new version, quits and replaces a running older copy, and opens it with no Gatekeeper prompt.
