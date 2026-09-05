#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
VERSION="0.56.5"
ARCHIVE="CodexBarCLI-v${VERSION}-macos-arm64.tar.gz"
SHA256="1d8499c3b7b3f023ef0258f14d18fc5947f9f9b329af864137d9ad0a3b7802e9"
CACHE_DIR="$PROJECT_DIR/.build/dependencies"
mkdir -p "$CACHE_DIR"
ARCHIVE_PATH="$CACHE_DIR/$ARCHIVE"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
    download_path="$(mktemp "$CACHE_DIR/codexbar-download.XXXXXX")"
    trap 'rm -f "$download_path"' EXIT
    curl --fail --location --retry 2 --connect-timeout 15 --max-time 180 \
        "https://github.com/steipete/CodexBar/releases/download/v${VERSION}/${ARCHIVE}" \
        --output "$download_path"
    actual="$(shasum -a 256 "$download_path" | awk '{print $1}')"
    [[ "$actual" == "$SHA256" ]] || { print -u2 "CodexBar checksum mismatch"; exit 1; }
    mv "$download_path" "$ARCHIVE_PATH"
    trap - EXIT
fi

actual="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
[[ "$actual" == "$SHA256" ]] || { print -u2 "Cached CodexBar checksum mismatch"; exit 1; }
DESTINATION="$PROJECT_DIR/Mac资源监控.app/Contents/Resources/Helpers/CodexBar"
mkdir -p "$DESTINATION"
tar -xzf "$ARCHIVE_PATH" -C "$DESTINATION" CodexBarCLI VERSION CodexBar_CodexBarCore.bundle
[[ -x "$DESTINATION/CodexBarCLI" ]]
[[ -d "$DESTINATION/CodexBar_CodexBarCore.bundle" ]]
codesign --force --sign - "$DESTINATION/CodexBarCLI"
CODEXBAR_RESOURCE_SMOKE=1 "$DESTINATION/CodexBarCLI" | grep -Fx CODEXBAR_RESOURCE_SMOKE_OK
