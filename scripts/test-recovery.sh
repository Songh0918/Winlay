#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/winlay-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$WORK/cache" -o "$WORK/recovery-tests" \
  "$ROOT/scripts/tests/RecoveryScenarios.swift" "$ROOT"/Winlay/Core/*.swift \
  "$ROOT/Winlay/Services/KeyboardDeviceManager.swift" "$ROOT/Winlay/Services/MappingService.swift" "$ROOT/Winlay/Services/AppModel.swift"
"$WORK/recovery-tests"
