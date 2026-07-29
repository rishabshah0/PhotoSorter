#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Terminate any running instance of the app first so the new build launches
killall PhotoSorter 2>/dev/null || true
sleep 0.2

open /Applications/PhotoSorter.app
