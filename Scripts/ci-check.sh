#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/Mac资源监控.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/MacResourceMonitor"
APP_HELPER="$APP_DIR/Contents/Resources/Helpers/whatcable-cli"
APP_INFO="$APP_DIR/Contents/Info.plist"

cd "$PROJECT_DIR"

echo "[1/6] Validate project metadata and scripts"
plutil -lint Info.plist
zsh -n build.sh
zsh -n Scripts/ci-check.sh
zsh -n Scripts/prepare-codexbar.sh
ruby -e 'require "yaml"; YAML.load_file(".github/workflows/ci.yml")'

app_version="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
build_number="$(plutil -extract CFBundleVersion raw Info.plist)"

[[ -f README.md ]]
[[ -f README.zh-CN.md ]]

grep -Fq -- 'href="README.zh-CN.md"' README.md
grep -Fq -- 'href="README.md"' README.zh-CN.md

grep -Fq -- "> Current version: **${app_version} (Build ${build_number})**" README.md
grep -Fq -- "version-${app_version}-" README.md
grep -Fq -- "## What's New in ${app_version}" README.md
grep -Fq -- "MacResourceMonitor-${app_version}.zip" README.md
grep -Fq -- "- App version: ${app_version}" README.md
grep -Fq -- "- Build: ${build_number}" README.md

grep -Fq -- "> 当前版本：**${app_version}（Build ${build_number}）**" README.zh-CN.md
grep -Fq -- "version-${app_version}-" README.zh-CN.md
grep -Fq -- "## ${app_version} 更新" README.zh-CN.md
grep -Fq -- "MacResourceMonitor-${app_version}.zip" README.zh-CN.md
grep -Fq -- "- App 版本：${app_version}" README.zh-CN.md
grep -Fq -- "- Build：${build_number}" README.zh-CN.md

echo "[2/6] Type-check Swift sources with warnings as errors"
xcrun swiftc \
  -swift-version 5 \
  -warnings-as-errors \
  -typecheck \
  -parse-as-library \
  -target arm64-apple-macos26.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework IOKit \
  -framework SystemConfiguration \
  Sources/CommandRunner.swift \
  Sources/CodexQuotaMonitor.swift \
  Sources/CodexQuotaView.swift \
  Sources/ProcessNetworkMonitor.swift \
  Sources/StorageManager.swift \
  Sources/CableMonitor.swift \
  Sources/MacResourceMonitor.swift

echo "[3/6] Build a fresh application bundle"
mkdir -p .build/tests
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Sources/CodexQuotaMonitor.swift Tests/CodexQuotaTests.swift \
  -o .build/tests/codex-quota-tests
.build/tests/codex-quota-tests
./build.sh >/dev/null

echo "[4/6] Verify bundle structure and metadata"
[[ -x "$APP_EXECUTABLE" ]]
[[ -x "$APP_HELPER" ]]
[[ -x "$APP_DIR/Contents/Resources/Helpers/CodexBar/CodexBarCLI" ]]
[[ -f "$APP_DIR/Contents/Resources/CodexQuotaConfig.json" ]]
[[ -f "$APP_DIR/Contents/Resources/CodexBarLicenses/CodexBar-MIT.txt" ]]
[[ -d "$APP_DIR/Contents/Resources/Helpers/CodexBar/CodexBar_CodexBarCore.bundle" ]]
[[ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ]]
[[ -f "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ -d "$APP_DIR/Contents/Resources/WhatCable_WhatCableCore.bundle" ]]
cmp -s Info.plist "$APP_INFO"
[[ "$(lipo -archs "$APP_EXECUTABLE")" == "arm64" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$APP_INFO")" == "io.github.svsvnm.MacResourceMonitor" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP_INFO")" == "$app_version" ]]
[[ "$(plutil -extract CFBundleVersion raw "$APP_INFO")" == "$build_number" ]]

echo "[5/6] Verify code signatures"
codesign --verify --strict "$APP_HELPER"
codesign --verify --strict "$APP_DIR/Contents/Resources/Helpers/CodexBar/CodexBarCLI"
codesign --verify --deep --strict "$APP_DIR"

echo "[6/6] Check repository diff hygiene"
git diff --check
git show --check --format=oneline HEAD >/dev/null

echo "CI checks passed for Mac 资源监控 ${app_version} (Build ${build_number})."
