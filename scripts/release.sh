#!/usr/bin/env bash
# Produces build/ClaudeUsage.zip — the GitHub release asset (unversioned name keeps latest/download stable).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
rm -f build/ClaudeUsage.zip
ditto -c -k --norsrc --keepParent "build/Claude Usage.app" build/ClaudeUsage.zip
shasum -a 256 build/ClaudeUsage.zip
echo "Release asset: build/ClaudeUsage.zip"
