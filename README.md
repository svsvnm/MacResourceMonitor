<p align="right">
  <a href="README.zh-CN.md">简体中文</a> | English
</p>

<p align="center">
  <img src="Assets/AppIcon.png" width="112" height="112" alt="Mac Resource Monitor icon">
</p>

<h1 align="center">Mac Resource Monitor</h1>

<p align="center">System metrics, process traffic, storage tools, and Codex quota — in one native macOS app.</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-0A84FF">
  <img alt="Version" src="https://img.shields.io/badge/version-2.6.0-7C3AED">
  <img alt="CI" src="https://github.com/svsvnm/MacResourceMonitor/actions/workflows/ci.yml/badge.svg">
</p>

> Current version: **2.6.0 (Build 45)**

A SwiftUI utility with a Liquid Glass interface and a compact menu bar panel. Check your Mac's resource usage, find bandwidth-heavy processes, inspect connected ports, and manage storage without switching between several apps.

## Download and Install

**[Download MacResourceMonitor-2.6.0.zip](https://github.com/svsvnm/MacResourceMonitor/releases/download/v2.6.0/MacResourceMonitor-2.6.0.zip)** · [Release notes and checksums](https://github.com/svsvnm/MacResourceMonitor/releases/latest)

Requires **macOS 26 or later and Apple Silicon**. Intel Macs and earlier macOS versions are not supported.

1. Download and extract the ZIP.
2. Quit any running copy, then drag **Mac资源监控.app** into Applications, replacing the old copy if updating.
3. Open the app from Applications. Closing its window keeps the menu bar monitor running; choose **Quit** in the menu to exit.

The app is ad-hoc signed, not Apple Developer ID signed or notarized. If macOS blocks opening it, review the source and use the approval option in **System Settings → Privacy & Security**. Do not disable system-wide security protections.

For an integrity check, download the matching `.zip.sha256` file into the same directory and run:

```zsh
shasum -a 256 -c MacResourceMonitor-2.6.0.zip.sha256
```

## Features

| Module | What it shows or does |
| --- | --- |
| System | CPU and memory usage, history, network rates, temperature, fans, battery and power readings, and process rankings |
| Process Traffic | Per-process download/upload rates, PID, search, sorting, and traffic accumulated during visible monitoring |
| AI Usage | Codex subscription quota remaining, available plan information, reset times, and manual refresh |
| Ports | Available USB-C, MagSafe, USB4, Thunderbolt, DisplayPort, USB-PD, and cable E-Marker information |
| Storage | Directory sizes, large files over 500 MB of allocated space, Finder shortcuts, and selected cache/log/Xcode/Trash cleanup |
| App Uninstaller | Third-party apps ranked by size; move selected apps and exact Bundle ID-matched remnants to Trash |

The menu panel includes key system readings, the **top three currently active processes by traffic**, and a shared Codex quota summary.

## Refresh and Power Use

- Lightweight system metrics refresh about every **2 seconds**. The menu bar title keeps displaying CPU temperature and network speed when the main window is closed.
- Process traffic runs only while the menu panel or Traffic page is visible. Both views share one collector; hiding both stops sampling and clears live rates.
- Expensive process rankings, fan, power, and cable queries follow the visibility of the relevant panels.
- The menu uses a shared display snapshot and stable inner surfaces to limit repeated UI updates and glass compositing.

Process traffic uses read-only snapshots from macOS `nettop`, with no VPN or Network Extension. It is **not a complete traffic ledger**: short-lived connections and traffic while hidden may be missing. It excludes local loopback and does not show domains, request contents, or connection rules.

## Set Up Codex Quota

1. Sign into Codex with your subscription account using the Codex CLI or a supported desktop app with a bundled CLI.
2. Open **AI 用量 (AI Usage)** in the sidebar, or open the menu panel.
3. Use **Refresh** after signing in or if a query fails.

This integration uses the bundled **CodexBar CLI v0.56.5**, with only the Codex CLI source enabled. It displays the quota windows actually returned by the account; missing data stays unavailable, never a fabricated zero. It does not measure API billing or redeem usage-reset credits.

Automatic queries run at most once per **minute** while either view is visible, or every **5 minutes** in Low Power Mode or under serious thermal pressure. Hiding both views cancels the query and stops scheduling. Transient failures mark cached results as stale; authentication failures clear them.

## Privacy, Safety, and Limits

- System and storage data are processed locally. The app has no telemetry upload. **Codex quota is an online feature** that queries through your signed-in Codex CLI; other modules do not require an account.
- The integration does not send chat contents, import browser cookies, or scan local cost history. Quota results are cached only in memory.
- Hardware and network monitoring are read-only: no fan control, charging-policy changes, or network reconfiguration.
- Cleanup requires confirmation and targets only the listed items. Personal folders are not automatically cleaned. App removal uses Trash; **emptying Trash is permanent**.
- Temperature, fan, charging, and cable fields depend on the hardware and data exposed by macOS. Negotiated USB-PD limits are not actual charging power.
- Protected directories, unindexed files, and cloud-only items may be missing from storage results. Unavailable readings and incomplete scans are reported instead of guessed.

## What's New in 2.6.0

- Added the Codex AI Usage page and menu summary with remaining quota and reset times.
- Added shared, visibility-aware quota refresh, bounded subprocess execution, and clear unavailable/stale/login states.
- Bundled a checksum-pinned CodexBar helper and dependency licenses, with offline regression tests.
- Rewrote both READMEs around current features, setup, and safety boundaries; removed the accumulated historical changelog.

Older release notes remain in [GitHub Releases](https://github.com/svsvnm/MacResourceMonitor/releases).

## Build and Test

Requires Xcode 26 Command Line Tools or Xcode 26 with a macOS 26 SDK. The build script invokes Swift directly; no Xcode project or package-manager setup is needed.

```zsh
git clone https://github.com/svsvnm/MacResourceMonitor.git
cd MacResourceMonitor
./build.sh
open "Mac资源监控.app"
```

The first build downloads the pinned arm64 CodexBar archive and verifies its SHA-256. Later builds reuse the verified cache. The app bundle includes helper resources and third-party licenses.

Run the same checks used by GitHub Actions:

```zsh
./Scripts/ci-check.sh
```

Checks cover version consistency, Swift warnings as errors, offline quota regression tests, a fresh app build, resources, architecture, and code signatures. Release ZIPs and checksums are built by GitHub Actions from the matching version tag; generated app bundles are not committed.

## Third-Party Components

- [Stats](https://github.com/exelban/stats): reference for Apple SMC access.
- [WhatCable](https://github.com/darrylmorley/whatcable): read-only port and cable diagnostics.
- [CodexBar](https://github.com/steipete/CodexBar): Codex subscription quota via its CLI.

See [third-party notices](THIRD_PARTY_NOTICES.md) and [CodexBar dependency licenses](Assets/CodexBarLicenses) for attribution and license texts.

## Version

- App version: 2.6.0
- Build: 45
- Bundle ID: `io.github.svsvnm.MacResourceMonitor`
- Target: macOS 26.0+, arm64
