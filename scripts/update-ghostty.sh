#!/usr/bin/env bash
# Update ghostty dependency to latest main branch
# Also maintains a source checkout for reference at deps/ghostty/
#
# Usage: ./scripts/update-ghostty.sh

set -euo pipefail

cd "$(dirname "$0")/.."

DEPS_DIR="deps/ghostty"
SERVER_DIR="server"

echo "=== Updating ghostty dependency ==="

# Fetch latest main and update build.zig.zon
cd "$SERVER_DIR"
echo "Fetching latest ghostty main..."
zig fetch --save=ghostty "git+https://github.com/ghostty-org/ghostty#main"

# Extract the commit hash from build.zig.zon
COMMIT=$(grep -o '#[a-f0-9]\{40\}' build.zig.zon | tr -d '#')
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
echo "Run 'cd server && zig build test' to verify."
