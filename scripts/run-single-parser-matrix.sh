#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

make server

./server/zig-out/bin/dullahan test single-parser-matrix "$@"
