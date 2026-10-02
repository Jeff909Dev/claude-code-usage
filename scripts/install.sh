#!/usr/bin/env bash
# Installs Claude Usage into /Applications and opens it:
#   curl -fsSL https://claude-code-usage.vercel.app/install.sh | bash
# curl doesn't mark what it downloads as quarantined, so macOS opens the app without the "Open Anyway" step.
# The site serves a copy of scripts/install.sh from the repo (github.com/Jeff909Dev/claude-code-usage).
#
# Overrides (for testing): CLAUDE_USAGE_ZIP_URL, CLAUDE_USAGE_APPS_DIR, CLAUDE_USAGE_NO_OPEN=1.
set -euo pipefail

ZIP_URL=${CLAUDE_USAGE_ZIP_URL:-https://github.com/Jeff909Dev/claude-code-usage/releases/latest/download/ClaudeUsage.zip}
APPS_DIR=${CLAUDE_USAGE_APPS_DIR:-/Applications}
APP_NAME="Claude Usage.app"
tmp=""

cleanup() { if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# PIDs of your copies of the app running from this bundle (other copies are left alone).
running_from() {
    local exe="$1/Contents/MacOS/ClaudeUsage" pid
    for pid in $(pgrep -x -u "$(id -u)" ClaudeUsage || true); do
        case "$(ps -o command= -p "$pid" 2>/dev/null || true)" in
            "$exe" | "$exe "*) printf '%s\n' "$pid" ;;
        esac
    done
}

quit_running() {
    local app="$1" pids tries=0
    pids=$(running_from "$app")
    [ -n "$pids" ] || return 0
    say "Quitting the running Claude Usage…"
    # shellcheck disable=SC2086  # one PID per word
    kill $pids 2>/dev/null || true
    while [ -n "$(running_from "$app")" ]; do
        tries=$((tries + 1))
        [ "$tries" -le 50 ] || die "Claude Usage didn't quit. Quit it from its menu, then run this again."
        sleep 0.1
    done
}

main() {
    [ "$(uname -s)" = Darwin ] || die "Claude Usage is a macOS app."
    local major
    major=$(sw_vers -productVersion | cut -d. -f1)
    [ "$major" -ge 14 ] || die "Claude Usage needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
    [ -d "$APPS_DIR" ] || die "$APPS_DIR doesn't exist."
    # Without symlinks: macOS reports a running app by this kind of path.
    APPS_DIR=$(cd "$APPS_DIR" && pwd -P)

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-install.XXXXXX")

    say "Downloading Claude Usage…"
    curl -fsSL "$ZIP_URL" -o "$tmp/ClaudeUsage.zip" || die "Couldn't download $ZIP_URL"
    mkdir "$tmp/unzipped"
    ditto -x -k "$tmp/ClaudeUsage.zip" "$tmp/unzipped" 2>/dev/null || die "The download isn't a valid zip."
    local new="$tmp/unzipped/$APP_NAME"
    [ -x "$new/Contents/MacOS/ClaudeUsage" ] || die "The zip doesn't contain $APP_NAME."
    codesign --verify --deep --strict "$new" 2>/dev/null || die "$APP_NAME's signature doesn't verify."

    local dest="$APPS_DIR/$APP_NAME" sudo=""
    # Ownership, not -w, for the old copy: macOS reports a just-launched app as briefly unwritable.
    if [ ! -w "$APPS_DIR" ] || { [ -e "$dest" ] && [ ! -O "$dest" ]; }; then
        say "You can't write to $APPS_DIR (or the copy there isn't yours), so this uses sudo: it may ask for your password."
        sudo="sudo"
    fi

    quit_running "$dest"
    say "Installing into ${dest}…"
    $sudo rm -rf "$dest"
    $sudo ditto "$new" "$dest"
    # Belt and braces: nothing here should be quarantined, but a quarantined app would be blocked on first launch.
    $sudo xattr -dr com.apple.quarantine "$dest"

    if [ "${CLAUDE_USAGE_NO_OPEN:-}" = 1 ]; then
        say "Installed $dest."
    else
        open "$dest"
        say "Installed and opened Claude Usage — look for ✻ in the menu bar."
    fi
}

# Everything runs from here, so a partly downloaded script runs nothing.
main "$@"
