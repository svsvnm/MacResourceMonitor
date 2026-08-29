<p align="right">
  <a href="README.zh-CN.md">简体中文</a> | English
</p>

<p align="center">
  <img src="Assets/AppIcon.png" width="112" height="112" alt="Mac Resource Monitor icon">
</p>

<h1 align="center">Mac Resource Monitor</h1>

<p align="center">
  A native, offline macOS performance and storage management utility that lives in the menu bar.
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-0A84FF">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white">
  <img alt="Version" src="https://img.shields.io/badge/version-2.5.4-7C3AED">
  <img alt="CI" src="https://github.com/svsvnm/MacResourceMonitor/actions/workflows/ci.yml/badge.svg">
</p>

Mac Resource Monitor combines system performance, per-process network traffic, hardware sensors, USB-C/Thunderbolt ports, disk space analysis, safe cleanup, and app removal in a single SwiftUI application. The main window uses the native Liquid Glass design of macOS 26. After the window is closed, the app remains in the menu bar and continues collecting lightweight system data; process traffic is sampled only while the menu popover or Traffic page is visible.

> Current version: **2.5.4 (Build 44)**. The project targets macOS 26 and Apple Silicon and does not include a compatibility layer for older systems.

## Feature Overview

| Module | Capabilities |
| --- | --- |
| System Monitor | CPU, memory, disk, network, CPU temperature, fans, charging power, process rankings, and historical charts |
| Process Traffic | Real-time per-process download/upload rates, PID, app icons, search, sorting, and cumulative traffic for the current monitoring session |
| Port Monitor | USB-C, MagSafe, USB4, Thunderbolt, DisplayPort, USB-PD, and cable E-Marker information |
| Storage Cleanup | Disk overview, largest directories, files larger than 500 MB, and cleanup for caches, logs, Xcode data, and Trash |
| App Uninstaller | Third-party apps ranked by size, Reveal in Finder, and moving app bundles plus remnants that exactly match their Bundle IDs to the Trash |

## What's New in 2.5.4

- Refined the typography and rebuilt the macOS 26 Liquid Glass hierarchy around restrained shell surfaces, stable telemetry panels, and clearer spacing in both the main window and menu bar.
- Converted the sidebar into a fully inset four-corner glass card and standardized shell, panel, card, control, and compact-element corner radii across the interface.
- Tightened the status header and 360-point menu panel, removed nested glass and oversized white surfaces, and changed app management from a stack of large cards to a compact grouped list.

## What's New in 2.5.3

- Redesigned the main window and menu bar interface around a compact telemetry workspace, combined load trends, consistent data colors, and clearer information hierarchy, reducing duplicate cards and decorative glass effects.
- Added accessible sample-by-sample exploration for CPU and memory history, and fixed the contrast of small data text in Dark Mode.
- The menu bar now shows only processes with current real-time traffic; stale rates are cleared after sampling failures, and hoverable error details take priority.

## What's New in 2.5.2

- Expanded Apple Silicon temperature-sensor support by selecting the appropriate SMC keys for each M1–M5 chip generation.
- Switched network rates to 64-bit interface counters and rebuilt the sampling baseline whenever the primary interface changes because of Wi-Fi, Ethernet, or VPN activity.
- Fixed races involving process PID reuse, cumulative-traffic resets, and in-flight sampling to prevent traffic from being attributed to the wrong process or stale data from being written back.
- Start and stop expensive process, SMC, power, and cable collection according to window, menu, and page visibility, reducing background CPU wakeups and power use.
- Strengthened freshness handling for extended metrics and cable results so older collection tasks can no longer overwrite the loading state of newer requests.
- Changed storage scanning to bounded-concurrency, independent `du -sk` tasks with correct handling for hard links, global timeouts, restricted permissions, and partial results.
- Large files are now measured by actual allocated space, with broader Spotlight filtering for physical size to avoid overestimating sparse files or missing files at the size boundary.

## What's New in 2.5.1

- Fixed high CPU usage and power consumption from process traffic monitoring: `nettop` no longer runs continuously and is instead queried about every 2 seconds for cumulative-byte snapshots, with deltas calculated inside the app.
- Process traffic is sampled only while the menu popover or the Traffic page in the main panel is visible. When both are closed, collection stops and live rates are cleared; traffic while hidden is not counted.
- Combined process traffic rows, rates, cumulative values, and status into a single publication to avoid triggering multiple SwiftUI refreshes during one sampling cycle.
- Refactored the menu bar refresh pipeline so system and traffic data share one display snapshot, submitting the full menu state only once every 2 seconds during steady operation.
- Kept a single Liquid Glass background for the menu and changed its internal metrics to stable translucent surfaces, reducing repeated WindowServer/GPU compositing work.
- Fixed an issue where an old timer could continue firing after the Traffic page was closed and reopened quickly, and strengthened handling for `nettop` timeouts and abnormal exits.

## What's New in 2.5.0

- Added a dedicated Process Traffic panel showing real-time download and upload rates, PID, and cumulative traffic for the current monitoring session by process.
- Uses the built-in macOS `nettop` utility for continuous, read-only sampling of external network interfaces without administrator privileges or a Network Extension.
- Supports searching by process name or PID and sorting by current transfer rate, download, upload, or cumulative traffic.
- Automatically resolves full process names and displays icons for running apps; cumulative records are retained briefly after a process exits.
- Excludes local loopback traffic, does not inspect communication contents or record domain names, and does not take over or modify network connections.
- Updated the menu bar popover to use bright, native Liquid Glass sampling and removed the full-surface dark overlay.
- Added the top three processes by real-time traffic to the menu bar popover, sharing results with the main panel rather than starting a second collector.

## What's New in 2.4.1

- Window transparency is now configured only once per `NSWindow`, preventing real-time data refreshes from repeatedly resetting the underlying surface and causing the foreground translucent glass window to flicker.
- Performance trend cards now use the same neutral surfaces as the home-page metric cards while retaining solid rendering and nonanimated refreshes to prevent white flashes.
- The System Monitor ring now clearly labels the higher of the CPU and memory values as “System Load”; the ring with no meaningful proportional value was removed from the App Uninstaller page.
- Removed the extra top offset from the main content area so the top overview card aligns precisely with the sidebar frame.
- Standardized the main window and menu bar on neutral graphite glass cards, removing large metric- and page-themed color washes from backgrounds.
- Standardized navigation and primary actions on a low-saturation steel blue-gray, reserving status colors for icons, progress bars, and charts.
- Reverted the experimental AppKit HUD/Popover `behindWindow` Vibrancy approach and restored the more stable SwiftUI ultra-thin material with dark overlays.
- Retained the removal of pause controls, single nonanimated history-chart refreshes, fixed heights, and solid backgrounds to prevent white flashes during synchronized updates.
- Retained stable solid cards for disk usage, large-file, safe-cleanup, and app-uninstaller lists to prevent translucent black artifacts while scrolling long lists.

## What's New in 2.3.10

- Removed duplicate pause buttons from the main interface and menu bar because they could easily lead to misreading stale data; monitoring now runs continuously.
- Consolidated history data from each collection cycle into one fixed-length, nonanimated update to prevent charts from redrawing repeatedly during a single refresh.
- Gave CPU and memory history charts fixed heights, clipped bounds, and stable solid cards, fixing momentary white flashes caused by Liquid Glass resampling every 2 seconds.

## What's New in 2.3.9

- Standardized the Disk Usage, Large Files, and Safe Cleanup lists on the independent rounded-card design language used by the App Uninstaller.
- Standardized icon containers, title hierarchy, size columns, card spacing, and Finder action buttons across all three management lists while retaining stable solid backgrounds to prevent glass compositing artifacts during scrolling.

## What's New in 2.3.8

- Long scrolling lists now use stable, opaque adaptive cards instead of handing an entire `LazyVStack` to real-time glass compositing, fixing item backgrounds that could briefly turn translucent black after scrolling.
- Disk usage results now filter out empty `0 KB` directories and retain at most 250 items, reducing invalid entries and scrolling overhead in very long lists.
- External commands now run through a shared isolated executor with timeouts, preventing cable detection, Spotlight, `du`, `ps`, or `pmset` failures from permanently occupying collection queues.
- Added Bundle ID format validation to remnant scanning, preventing nonstandard identifiers from being interpolated into user-directory paths.

## What's New in 2.3.7

- Removed the icon from the menu bar status item, which now always displays CPU temperature and real-time network download and upload rates.
- Redesigned the menu bar popover with the same results-first card layout as the main window, prominently displaying temperature and network activity with secondary CPU, memory, fan, port, and charging status.
- Dark Mode now uses a deep black background with restrained themed ambient lighting, reducing conventional list separators and gray backing panels.

## What's New in 2.3.6

- Removed the “Collapse to Menu Bar” button from the sidebar status card; the window continues to use the native macOS close action.
- Dark Mode now uses an opaque deep black background with only subtle themed ambient light, preventing the system window's gray color from showing through Liquid Glass.

## What's New in 2.3.5

- Total, used, and available disk space now consistently use `volumeAvailableCapacityForImportantUsage` semantics and decimal file-size formatting to match macOS System Settings.
- Removed the large `GlassEffectContainer` that covered the entire scrolling content area, constrained glass compositing to the scroll viewport, and added a soft bottom scroll edge to prevent black curved afterimages from offscreen glass cards.

## What's New in 2.3.4

- Sidebar section headings now use only stronger text color and weight, without strip backgrounds.
- Removed decorative shadows from the sidebar panel, app icon, selection indicator, and online status dot for a cleaner, more restrained interface.

## What's New in 2.3.3

- Fixed an issue where the top button in Port Monitor could be ignored by normal refresh throttling; it now forces one cable and port collection pass and displays an in-progress state plus the most recent detection time.
- Storage Cleanup and App Uninstaller now retain only their primary scan buttons in the top Hero area, removing duplicate refresh actions from the pages.
- Increased the contrast of sidebar section headings to make the hierarchy between “Overview” and “Management Tools” clearer.

## What's New in 2.3.2

- Changed all content cards, status Heroes, sidebar panels, and storage task cards to native Clear Liquid Glass, removing the prominent light-colored highlight edges produced by Regular Glass.
- Retained functional outlines for buttons, progress rings, and chart lines, while no longer drawing a separate white border around any card.

## What's New in 2.3.1

- Replaced the full-height rectangular sidebar with an independent rounded glass panel, eliminating abrupt seams at the title bar and bottom of the window.
- Removed extra white strokes around cards and colored backing panels that obscured the glass, allowing native Liquid Glass to sample the background directly.
- Standardized corner radii across panels, cards, and controls, and replaced multiple high-saturation light spots with a continuous, low-saturation ambient gradient.
- Standardized the former module name as “Port Monitor.”

## What's New in 2.3.0

- Redesigned the global visual hierarchy so every module uses its own status Hero to present conclusions, key values, and a single primary action first.
- Reorganized sidebar navigation into “Overview” and “Management Tools”; inactive items remain lightweight, while the current module uses a dynamic accent color and status indicator.
- Reworked System Monitor into a complete 4×2 metric grid, with separate sections for real-time resources, performance trends, and activity details.
- Rebuilt the Storage home page around a disk-status Hero and three task cards, eliminating a duplicate disk overview.
- Applied native Liquid Glass, ambient color, and subtle depth to cards throughout the app, with theme colors that switch automatically by module.
- Preserved the read-only data boundary, secondary cleanup confirmation, persistent menu bar behavior, and all hardware telemetry capabilities.

## What's New in 2.2.1

- Rebuilt the Storage module as a fixed home page with three feature cards; Disk Usage, Large Files, and Safe Cleanup now open as separate secondary pages.
- Changed long directory lists to lazy loading so growing scan results do not slow down the home page or initial rendering.
- Fixed a missing SF Symbol icon for the Large Files entry on macOS 26.
- Changed the Bundle ID to the public repository identity `io.github.svsvnm.MacResourceMonitor`, removing traces of local account names.
- Preserved existing behavior, including remaining in the menu bar after the window closes and collecting real-time sensor and charging-power data.

## System Monitor

- Refreshes CPU, memory, and primary network-interface data every 2 seconds, using 64-bit interface counters and rebuilding the rate baseline when the primary interface changes.
- Shows approximately the last 2 minutes of CPU and memory trends.
- Selects Apple SMC CPU temperature sensors by M1–M5 chip generation and displays average and peak values.
- Reads the number of built-in fans and their real-time speeds; explicitly displays `0 RPM` when fans stop at low temperatures.
- Reads the processes with the highest CPU usage, including PID, CPU percentage, and memory usage, only while the System Monitor page is visible.
- Displays battery status, power source, system thermal state, uptime, and device name.
- The menu bar title always shows CPU temperature and network upload/download rates; the popover provides key metrics and connected ports.

## Process Traffic Monitoring

- Uses the built-in macOS `nettop` utility on demand to read actual cumulative bytes sent and received by process over external network interfaces. While the menu popover or Traffic page is open, it obtains an instantaneous snapshot about every 2 seconds and calculates deltas inside the app; collection stops when both are closed.
- Separately displays each process's name, PID, current download rate, current upload rate, and cumulative traffic for the current monitoring session.
- Supports searching by process name or PID and sorting by current transfer rate, download, upload, or cumulative value.
- Resolves full process names and displays the corresponding app icon for graphical applications.
- Runs with standard user privileges, installs no system extension, enables no VPN, and does not compete with proxy tools such as Surge for network configuration.
- Provides process-level aggregate statistics without reading domain names, remote addresses, connection contents, or individual request records.

## Real-Time Charging Power

The app reads local power telemetry from `AppleSmartBattery` and distinguishes among the following concepts:

- **Adapter input power**: The power currently supplied by the power adapter to the entire system.
- **Actual battery charging power**: The real-time power actually entering the battery.
- **System power consumption**: The power currently consumed by the entire system.
- **USB-PD negotiated limit**: The port's negotiated capability, which is never mislabeled as real-time charging power.

When no power source is connected, the battery is full, or the system does not provide the relevant field, the interface displays the actual state or “Unavailable” rather than presenting an estimate as a measurement.

## Port and Cable Monitoring

- A dedicated Port Monitor module, separate from the CPU and memory page.
- Identifies USB-C, MagSafe, and available physical port states.
- Displays active USB 2, USB 3, USB4, Thunderbolt, and DisplayPort links.
- Displays USB-PD negotiated power, voltage, current, and potential charging bottlenecks.
- When macOS supplies the data, displays the cable E-Marker's rated speed, power, vendor, and capability assessment.
- The built-in WhatCable detection engine uses `--json --no-usb-probe` and does not perform deep control transfers against USB devices.

## Space Analysis and Safe Cleanup

The Storage Cleanup page first explains what is using disk space, then provides a limited set of explicit cleanup actions.

The Storage home page uses three navigable Liquid Glass feature cards and retains only the disk overview plus entries for Disk Usage, Large Files, and Safe Cleanup. Detailed lists and actions live on their respective secondary pages. Long lists are not retained after returning to the home page, and adding more tools later will not cause the home page to grow without limit.

### Read-Only Space Analysis

- Lists the largest items in `/Applications`, the home directory, and `~/Library` by actual size.
- Further breaks down `Application Support`, app containers, group containers, and developer-tool data instead of reporting only a vague, oversized “Library” category.
- Uses the local Spotlight index to list up to 20 large files occupying more than 500 MB of actual disk space; sparse files are measured by allocated space.
- Measures directory and app sizes with batched `du` operations rather than starting an external process for every item; clearly indicates when results are incomplete because of timeouts or restricted permissions.
- Every directory and large file can be revealed in Finder.
- Large files and personal directories are displayed read-only and are never included in one-click cleanup.

### Items That Can Be Cleaned

| Category | Selected by Default | Behavior |
| --- | --- | --- |
| User app caches | Yes | Deletes regenerable contents of `~/Library/Caches` while preserving this app's detection-component cache |
| User logs and crash reports | Yes | Cleans user-level logs in `~/Library/Logs` |
| Xcode DerivedData | No | Deletes regenerable build caches |
| Trash | No | Permanently deletes its contents; the interface displays an irreversible-action warning and asks for confirmation again |

Documents, photos, downloads, Desktop items, movies, music, and other personal content are never cleaned automatically. Content protected by macOS privacy controls or stored only in the cloud may not be measurable.

## App Uninstaller

- Scans third-party apps in `/Applications` and `~/Applications` and sorts them by size.
- Excludes system apps, symbolic links, and Mac Resource Monitor itself.
- Removes app bundles through the macOS Trash mechanism, so they can normally be restored.
- Processes only caches, preferences, containers, WebKit data, HTTPStorage, logs, and launch items that exactly match the app's Bundle ID.
- Never bulk-deletes files using fuzzy name matching and never resets global login-item, privacy, or background-item databases.
- System-level or protected apps may require administrator privileges; the app retains anything it is not authorized to remove and reports the failure.

## Liquid Glass Interface

- Native macOS 26 Liquid Glass is used for the sidebar, status headers, process-filter shell, and menu root panel; dense menus use the more robust Regular glass, and buttons use `.glass` / `.glassProminent`.
- Real-time telemetry, historical trends, and long lists use stable translucent surfaces to prevent high-frequency refreshes from triggering large-area glass resampling.
- Text throughout the app uses a semantic type hierarchy starting at 11–13 pt, with compact monospaced styling retained for timestamps and units.
- The persistent sidebar is grouped into Overview and Management Tools, and switching modules automatically returns the content to the top.
- Each module has a results-first status header that establishes a visual focal point through its title, status, key value, and single primary action.
- Ambient glow and translucent windows support both Light and Dark appearances while preserving native window controls.

## Menu Bar and Window Behavior

- Closing the main window does not quit the app. The Dock icon is hidden, and the menu bar retains only lightweight collection for CPU, memory, temperature, and network data; helpers for process rankings, fans, power, and cables start and stop according to panel visibility.
- Process traffic sampling stops when both the menu popover and Traffic page are closed.
- The menu bar popover can reopen the main panel or quit the app.
- The menu bar popover displays the top three processes by current traffic, including each process's real-time download and upload rates.
- System metrics and the top three processes in the menu popover both update about every 2 seconds; process traffic in the main panel updates at the same approximate interval.
- Closing the main window does not stop menu bar monitoring; reopen it from the menu bar when needed.
- The process ends only when you choose Quit or press `Command + Q`.

## Privacy and Security Boundaries

- All data is read and processed locally. No account is required, and no telemetry is uploaded.
- The Bundle ID is `io.github.svsvnm.MacResourceMonitor`, matching the public repository, and contains no local account name, device name, or absolute user path.
- The public repository does not include local build artifacts, scan results, or runtime screenshots containing personal file paths.
- System, SMC, port, and power collection operations are read-only.
- The app does not control fans, modify charging policies, change port configuration, or alter network settings.
- Cleanup operations target only paths explicitly listed in the interface and require a second confirmation before execution.
- App removal uses the Trash. Emptying the Trash is itself a permanent deletion and is not selected by default.
- Protected directories that cannot be read are skipped; the app never bypasses permissions by weakening system security settings.

## System Requirements

- macOS 26.0 or later.
- Apple Silicon (the current build target is `arm64-apple-macos26.0`).
- Xcode 26 Command Line Tools or the full Xcode 26 application to build from source.
- Availability of temperature, fan, cable, and power fields depends on the Mac model and whether macOS exposes the corresponding data.

## Download and Installation

Download `MacResourceMonitor-2.5.4.zip` from [GitHub Releases](https://github.com/svsvnm/MacResourceMonitor/releases/latest), extract it, and drag `Mac资源监控.app` into the Applications folder.

Pushing a matching `v*` tag builds the release archive from that tag on a macOS 26 GitHub Actions runner, uploads the ZIP and SHA-256 checksum, and publishes the GitHub Release automatically. The app is ad-hoc signed, but it is not currently signed with an Apple Developer ID or notarized. If Gatekeeper blocks the first launch, Control-click the app in Finder, choose Open, and continue after confirming the source.

## Building from Source

The project does not depend on an Xcode project, Swift Package Manager, or any third-party package manager. The build script invokes the system Swift compiler directly.

```zsh
git clone https://github.com/svsvnm/MacResourceMonitor.git
cd MacResourceMonitor
chmod +x build.sh
./build.sh
```

After a successful build, the following is created in the repository root:

```text
Mac资源监控.app
```

Launch the local build:

```zsh
open "Mac资源监控.app"
```

Install it in the Applications folder:

```zsh
ditto "Mac资源监控.app" "/Applications/Mac资源监控.app"
open "/Applications/Mac资源监控.app"
```

`build.sh` performs the following steps:

1. Creates a standard `.app` bundle directory.
2. Copies `Info.plist`, the app icon, third-party notices, and WhatCable runtime resources.
3. Uses the Swift compiler to link SwiftUI, AppKit, IOKit, and SystemConfiguration.
4. Ad-hoc signs the WhatCable helper and the final app locally.

Before submitting changes, run the same complete checks used by GitHub Actions:

```zsh
./Scripts/ci-check.sh
```

These checks verify consistency between metadata and the README version, type-check Swift with warnings treated as errors, build a clean app bundle, and validate the arm64 architecture, resource integrity, and code signature.

Verify the signature:

```zsh
codesign --verify --deep --strict --verbose=2 "Mac资源监控.app"
```

> The repository does not include generated `.app` bundles. Official release archives are rebuilt by GitHub Actions from the source for the corresponding tag and then uploaded.

## Project Structure

```text
MacResourceMonitor/
├── Assets/
│   ├── AppIcon.icns
│   ├── AppIcon.png
│   ├── AppIcon.iconset/
│   └── WhatCableHelper/
├── Scripts/
│   ├── ci-check.sh
│   └── make-rounded-icon.swift
├── Sources/
│   ├── CableMonitor.swift
│   ├── CommandRunner.swift
│   ├── MacResourceMonitor.swift
│   ├── ProcessNetworkMonitor.swift
│   └── StorageManager.swift
├── Info.plist
├── README.md
├── README.zh-CN.md
├── THIRD_PARTY_NOTICES.md
└── build.sh
```

- `MacResourceMonitor.swift`: System collection, SMC, power telemetry, the Liquid Glass main interface, menu bar, and app lifecycle.
- `CableMonitor.swift`: Safe staging and execution of the WhatCable helper, JSON parsing, and port snapshots.
- `CommandRunner.swift`: Isolates external-command output and enforces timeouts to prevent blocked pipes from stalling collection tasks.
- `ProcessNetworkMonitor.swift`: `nettop` process traffic sampling, the cumulative model, search and sorting, and the Traffic panel.
- `StorageManager.swift`: Disk usage, directory and large-file analysis, cleanup categories, and app removal.
- `build.sh`: Reproducible arm64 app-bundle build and signing script.

## Known Limitations

- SMC keys and hardware sensors vary by model; fields display “Unavailable” when they cannot be read.
- Standard 3A cables, charge-only cables, and some adapters may not provide E-Marker information.
- Files that Spotlight has not indexed, files restricted by privacy controls, and cloud-only files may not appear in the large-file list.
- `du` can measure only directories the current user has permission to read.
- Process traffic comes from external-interface sockets currently visible to `nettop` and is sampled only while the menu popover or Traffic page is visible. Connections shorter than the sampling interval or active while the interface is hidden may not produce complete cumulative records, and local loopback communication is excluded.
- The Process Traffic panel does not provide a Surge-style view of domains, requests, or connection rules. Implementing this kind of data-path visibility requires a Network Extension entitlement and signed system extension.
- The current build is arm64 only and does not support Intel Macs.

## Third-Party Components

- Apple SMC reading structures and access patterns are based on [Stats](https://github.com/exelban/stats).
- USB-C, USB-PD, E-Marker, DisplayPort, and Thunderbolt diagnostics use the read-only command-line engine from [WhatCable](https://github.com/darrylmorley/whatcable), pinned to source revision `82fded6f428ddfc79dfb204bf0b8e049ef6a8c32`.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for complete copyright and MIT license texts. Those notices apply only to the corresponding third-party components.

## Version Information

- App version: 2.5.4
- Build: 44
- Bundle ID: `io.github.svsvnm.MacResourceMonitor`
- Minimum system version: macOS 26.0
- Build architecture: arm64
