#!/bin/bash
# Собирает .app-бандл в корне проекта, чтобы открыть его из Finder двойным кликом.
# Запуск: ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

EXEC_NAME="YTComments"
APP_NAME="YT Comments Analyzer"
BUNDLE="${APP_NAME}.app"
BUILD_DIR=".build/release"

echo "==> Building (release)…"
swift build -c release

echo "==> Assembling ${BUNDLE}…"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${EXEC_NAME}" "${BUNDLE}/Contents/MacOS/${EXEC_NAME}"
cp "Info.plist"               "${BUNDLE}/Contents/Info.plist"

# Ad-hoc подпись, чтобы Gatekeeper пускал локальный бандл без «ПКМ -> Открыть».
codesign --force --sign - "${BUNDLE}" >/dev/null 2>&1 || true

echo "==> Done: ${BUNDLE}"
echo "    Launch:  open \"${BUNDLE}\""
echo "    Install: cp -R \"${BUNDLE}\" /Applications/"
