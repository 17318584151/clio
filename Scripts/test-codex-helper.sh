#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/clio-helper-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
clang -Wall -Wextra -Werror -O2 "$root/Tools/CodexHelper/main.c" -o "$scratch/CodexHelper"
CLIO_HELPER_BINARY="$scratch/CodexHelper" /usr/bin/python3 -I -B "$root/Tests/CodexHelperTests.py"
