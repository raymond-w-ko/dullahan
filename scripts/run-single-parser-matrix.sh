#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

(
  cd server
  zig build
)

./server/zig-out/bin/dullahan test single-parser-matrix "$@"
