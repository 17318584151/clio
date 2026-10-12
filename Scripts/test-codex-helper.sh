#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-helper-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
clang -Wall -Wextra -Werror -O2 "$root/Tools/CodexHelper/main.c" -o "$scratch/CodexHelper"
helper="$scratch/CodexHelper.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp "$scratch/CodexHelper" "$helper/Contents/MacOS/"
cp "$root/Tools/CodexHelper/Info.plist" "$helper/Contents/"
cp "$root/Resources/AppIcon.icns" "$helper/Contents/Resources/"
codesign --force --sign - "$helper"
CLIO_HELPER_BINARY="$scratch/CodexHelper" /usr/bin/python3 -I -B "$root/Tests/CodexHelperTests.py"
