#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-menubar-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

"$root/build/Clio" --snapshot "$scratch/standalone" --menubar-only
"$root/build/Clio.app/Contents/MacOS/Clio" --snapshot "$scratch/bundled" --menubar-only
for image in menubar-quota.png menubar-orbit.png; do
    test -s "$scratch/standalone/$image"
    cmp "$scratch/standalone/$image" "$scratch/bundled/$image"
done

cp "$root/build/Clio" "$scratch/Clio"
"$scratch/Clio" --snapshot "$scratch/missing-resource" --menubar-only
test -s "$scratch/missing-resource/menubar-orbit.png"
echo "Menu bar resource checks passed"
