#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-menubar-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

"$root/build/Clio" --snapshot "$scratch/standalone" --menubar-only
"$root/build/Clio.app/Contents/MacOS/Clio" --snapshot "$scratch/bundled" --menubar-only
test -s "$scratch/bundled/menubar.png"
test -s "$root/build/Clio.app/Contents/Resources/AppIcon.icns"
test -s "$scratch/standalone/menubar-quota.png"
cmp "$scratch/standalone/menubar-quota.png" "$scratch/bundled/menubar-quota.png"
echo "Menu bar resource checks passed"
