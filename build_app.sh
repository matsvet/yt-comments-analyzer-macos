#!/bin/bash
# Собирает .app-бандл в корне проекта, чтобы открыть его из Finder двойным кликом.
# Запуск: ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

EXEC_NAME="YTComments"
APP_NAME="YT Comments Analyzer"
BUNDLE="${APP_NAME}.app"
# Кэш вне Google Drive: облачные метаданные мешают codesign.
BUILD_ROOT="${TMPDIR:-/tmp}/yt-comments-analyzer-build"
if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    DEFAULT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
else
    DEFAULT_SDK="$(xcrun --show-sdk-path)"
fi
SDK_PATH="${SDKROOT:-$DEFAULT_SDK}"

echo "==> Building (release)…"
swift build -c release --scratch-path "$BUILD_ROOT" --sdk "$SDK_PATH"
BUILD_DIR="$(swift build -c release --scratch-path "$BUILD_ROOT" --sdk "$SDK_PATH" --show-bin-path)"

echo "==> Assembling ${BUNDLE}…"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXEC_NAME}" "${BUNDLE}/Contents/MacOS/${EXEC_NAME}"
cp "Info.plist"               "${BUNDLE}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc подпись, чтобы Gatekeeper пускал локальный бандл без «ПКМ -> Открыть».
codesign --force --sign - "${BUNDLE}" >/dev/null 2>&1 || true

echo "==> Done: ${BUNDLE}"
echo "    Launch:  open \"${BUNDLE}\""
echo "    Install: cp -R \"${BUNDLE}\" /Applications/"
