#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="$1"
mkdir -p "$output"
clang -O2 -target arm64-apple-macosx14.0 \
    -isysroot "$(xcrun --show-sdk-path)" \
    -c "$root/Sources/CZstd/vendor/zstddeclib.c" \
    -o "$output/zstddeclib.o"
