#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
CLANG_MODULE_CACHE_PATH="$root/build/ModuleCache" swiftc -swift-version 5 \
    -o "$root/build/codex-helper-state-tests" \
    "$root/Sources/Clio/Data/AppPaths.swift" \
    "$root/Sources/Clio/Data/CodexHelper.swift" \
    "$root/Tests/CodexHelperStateTests.swift"
"$root/build/codex-helper-state-tests"
