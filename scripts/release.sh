#!/usr/bin/env bash
# Produces build/ClaudeUsage.zip — the GitHub release asset (unversioned name keeps latest/download stable).
# With DEVELOPER_ID_APP ("Developer ID Application: Name (TEAMID)") and NOTARY_PROFILE (a profile saved with
# `xcrun notarytool store-credentials`) set, the app is signed with that identity and the hardened runtime, notarized
# and stapled, so macOS opens the downloaded app without asking. Without them it stays ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Claude Usage.app"
ZIP=build/ClaudeUsage.zip

notarize=false
if [[ -n "${DEVELOPER_ID_APP:-}${NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${DEVELOPER_ID_APP:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
        echo "Set both DEVELOPER_ID_APP and NOTARY_PROFILE to notarize, or neither for an ad-hoc build." >&2
        exit 1
    fi
    notarize=true
fi

./scripts/bundle.sh
rm -f "$ZIP"

if $notarize; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "$APP"
    codesign --verify --deep --strict "$APP"
    # notarytool takes a zip of the app; the stapled app is zipped again below for the release.
    ditto -c -k --norsrc --keepParent "$APP" build/notarize.zip
    xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    rm build/notarize.zip
    # Fails unless Apple accepted the submission.
    xcrun stapler staple "$APP"
else
    echo "Ad-hoc signed, not notarized (set DEVELOPER_ID_APP and NOTARY_PROFILE to notarize)."
fi

ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP"
echo "Release asset: $ZIP"
