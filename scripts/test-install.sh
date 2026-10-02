#!/usr/bin/env bash
# Tests scripts/install.sh with local zips, installing into a temp folder — never /Applications, never a running app
# outside that folder.
set -euo pipefail
cd "$(dirname "$0")/.."

# Without symlinks (TMPDIR has one): macOS reports a running app by this kind of path.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-install-test.XXXXXX")" && pwd -P)
pids=""
cleanup() {
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

# Runs the installer quietly; prints its output when it fails. Returns the installer's exit code.
install_from() {  # install_from <zip url> <apps dir>
    local status=0
    CLAUDE_USAGE_ZIP_URL="$1" CLAUDE_USAGE_APPS_DIR="$2" CLAUDE_USAGE_NO_OPEN=1 \
        bash scripts/install.sh >"$work/install.log" 2>&1 || status=$?
    return "$status"
}

# A stand-in for the app: a binary named ClaudeUsage that runs until it is told to quit, ad-hoc signed like a release.
make_app() {  # make_app <dir> → <dir>/Claude Usage.app
    local app="$1/Claude Usage.app"
    mkdir -p "$app/Contents/MacOS"
    printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' | cc -x c - -o "$app/Contents/MacOS/ClaudeUsage"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIdentifier</key><string>example.claude-usage.install-test</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app" 2>/dev/null
}

# Starts the app's binary in the background; sets `started` to its PID. Disowned: bash doesn't announce its end.
start() {
    "$1/Contents/MacOS/ClaudeUsage" >/dev/null 2>&1 &
    started=$!
    disown "$started"
    pids="$pids $started"
}
# A process that exited but wasn't reaped yet is a zombie ("Z"); either way it's gone.
is_running() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in ""|Z*) return 1 ;; *) return 0 ;; esac; }
has_quarantine() { xattr -lr "$1" | grep -q com.apple.quarantine; }

cmp -s scripts/install.sh site/install.sh || fail "site/install.sh differs from scripts/install.sh"
pass "the site serves the same script"

# A browser download marks the app as quarantined; the zip keeps that attribute (ditto stores extended attributes).
make_app "$work/release"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$work/release/Claude Usage.app"
xattr -w com.apple.quarantine "0083;00000000;Safari;" "$work/release/Claude Usage.app/Contents/MacOS/ClaudeUsage"
ditto -c -k --keepParent "$work/release/Claude Usage.app" "$work/ClaudeUsage.zip"
mkdir "$work/check" && ditto -x -k "$work/ClaudeUsage.zip" "$work/check"
has_quarantine "$work/check/Claude Usage.app" || fail "the test zip should carry com.apple.quarantine"
zip_url="file://$work/ClaudeUsage.zip"

apps="$work/Applications"
mkdir "$apps"
app="$apps/Claude Usage.app"
install_from "$zip_url" "$apps" || { cat "$work/install.log"; fail "a fresh install failed"; }
[ -x "$app/Contents/MacOS/ClaudeUsage" ] || fail "the app wasn't installed"
! has_quarantine "$app" || fail "the installed app is still quarantined"
codesign --verify --deep --strict "$app" || fail "the installed app's signature doesn't verify"
pass "installs into an empty folder, without quarantine, with a valid signature"

touch "$app/Contents/stale"
start "$app"
running=$started
make_app "$work/elsewhere"
start "$work/elsewhere/Claude Usage.app"
other=$started
# Named through a symlink, the folder still matches the running copy's path.
ln -s "$apps" "$work/linked-apps"
install_from "$zip_url" "$work/linked-apps" || { cat "$work/install.log"; fail "replacing an install failed"; }
[ ! -e "$app/Contents/stale" ] || fail "the old copy's files survived"
codesign --verify --deep --strict "$app" || fail "the replaced app's signature doesn't verify"
! is_running "$running" || fail "the copy being replaced is still running"
is_running "$other" || fail "a copy outside the install folder was quit"
pass "replaces the installed copy and quits it, leaving other copies running"

mkdir -p "$work/wrong/Something Else.app"
ditto -c -k --keepParent "$work/wrong/Something Else.app" "$work/wrong.zip"
touch "$app/Contents/kept"
! install_from "file://$work/wrong.zip" "$apps" || fail "a zip without Claude Usage.app was installed"
grep -q "Claude Usage.app" "$work/install.log" || fail "the refusal doesn't say what was missing"
! install_from "file://$work/missing.zip" "$apps" || fail "a failed download was installed"
[ -e "$app/Contents/kept" ] || fail "a failed install touched the installed copy"
pass "refuses a wrong zip or a failed download and keeps the installed copy"
