#!/usr/bin/env bash
# Update ghostty dependency to latest main branch
# Also maintains a source checkout for reference at deps/ghostty/
#
# Usage: ./scripts/update-ghostty.sh

set -euo pipefail

cd "$(dirname "$0")/.."

DEPS_DIR="deps/ghostty"
SERVER_DIR="server"
EXPECTED_ZIG_VERSION="0.17.1"

actual_zig_version="$(zig version)"
if [ "$actual_zig_version" != "$EXPECTED_ZIG_VERSION" ]; then
    echo "error: Zig $EXPECTED_ZIG_VERSION required; found $actual_zig_version" >&2
    exit 1
fi

echo "=== Updating ghostty dependency ==="

# Fetch latest main and update build.zig.zon
cd "$SERVER_DIR"
echo "Fetching latest ghostty main..."
zig fetch --save=ghostty "git+https://github.com/ghostty-org/ghostty#main"

# Extract the ghostty commit hash from build.zig.zon
COMMIT=$(grep 'ghostty-org/ghostty' build.zig.zon | grep -o '#[a-f0-9]\{40\}' | tr -d '#')
echo "Resolved commit: $COMMIT"

cd ..

# Maintain source checkout for reference
echo ""
echo "=== Updating source checkout ==="

if [ ! -d "$DEPS_DIR" ]; then
    echo "Cloning ghostty repository..."
    mkdir -p deps
    git clone https://github.com/ghostty-org/ghostty.git "$DEPS_DIR"
else
    echo "Fetching latest changes..."
    git -C "$DEPS_DIR" fetch origin
fi

echo "Checking out commit $COMMIT..."
git -C "$DEPS_DIR" checkout "$COMMIT" --quiet

echo ""
echo "=== Done ==="
echo "Dependency updated in server/build.zig.zon"
echo "Source checkout at $DEPS_DIR (commit: $COMMIT)"
echo ""
echo "Run 'make test-server' to verify."
