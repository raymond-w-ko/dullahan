#!/usr/bin/env bash
# Update ghostty dependency to latest main branch
#
# Usage: ./scripts/update-ghostty.sh

set -euo pipefail

cd "$(dirname "$0")/../server"

echo "Fetching latest ghostty main..."
zig fetch --save=ghostty "git+https://github.com/ghostty-org/ghostty#main"

echo ""
echo "Updated! Run 'zig build test' to verify."
