#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/winlay-scroll-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$WORK/cache" -o "$WORK/scroll-tests" \
  "$ROOT/scripts/tests/ScrollScenarios.swift" "$ROOT"/Winlay/Core/*.swift "$ROOT/Winlay/Services/MouseScrollService.swift"
"$WORK/scroll-tests"
