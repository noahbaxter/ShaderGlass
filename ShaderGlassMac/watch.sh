#!/bin/bash
# Watch mode - auto-rebuilds and reloads when source files change
# Requires: brew install fswatch

set -e
cd "$(dirname "$0")"

# Initial build
./dev.sh

echo ""
echo "Watching for changes... (Ctrl+C to stop)"
echo ""

# Watch source files and rebuild on change
fswatch -o src/*.mm src/*.h src/*.metal | while read; do
    echo ""
    echo "Change detected, rebuilding..."
    ./dev.sh
done
