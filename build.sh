#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/PhotoSorter.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
CONTENTS_DIR="${APP_DIR}/Contents"

echo "1. Cleaning previous builds..."
rm -rf "${BUILD_DIR}"
mkdir -p "${MACOS_DIR}"

echo "2. Compiling Swift files..."
# Compiles all Swift files inside Sources/ with optimization (-O)
swiftc -O -sdk "$(xcrun --show-sdk-path)" \
       -o "${MACOS_DIR}/PhotoSorter" \
       "${SCRIPT_DIR}/Sources/"*.swift

echo "3. Copying Info.plist..."
cp "${SCRIPT_DIR}/Sources/Info.plist" "${CONTENTS_DIR}/Info.plist"

echo "3.5. Copying AppIcon.icns..."
mkdir -p "${CONTENTS_DIR}/Resources"
cp "${SCRIPT_DIR}/AppIcon.icns" "${CONTENTS_DIR}/Resources/AppIcon.icns"

echo "4. Performing ad-hoc code signing..."
# Applies ad-hoc signing with the entitlements file
codesign -s - --force --entitlements "${SCRIPT_DIR}/entitlements.plist" "${APP_DIR}"

echo "5. Copying to /Applications..."
killall PhotoSorter 2>/dev/null || true
sleep 0.2
rm -rf /Applications/PhotoSorter.app
cp -R "${APP_DIR}" /Applications/
codesign -s - --force --entitlements "${SCRIPT_DIR}/entitlements.plist" /Applications/PhotoSorter.app

echo "6. Invalidating macOS Launch Services / Icon Cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PhotoSorter.app
touch /Applications/PhotoSorter.app

echo "Build & Installation Successful: /Applications/PhotoSorter.app"
