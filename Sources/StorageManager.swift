import SwiftUI
import AppKit
import Combine

struct CleanupCategory: Identifiable, Equatable {
    enum Kind: String {
        case caches
        case logs
        case xcodeDerivedData
        case trash
    }

    let kind: Kind
    let title: String
    let detail: String
    let symbol: String
    let path: String
    var bytes: UInt64
    var itemCount: Int
    var isSelected: Bool
    let isIrreversible: Bool

    var id: String { kind.rawValue }
}

struct InstalledApplication: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    let bundleIdentifier: String?
    let path: String
    let bytes: UInt64
    let needsAdministrator: Bool
}

struct StorageLocation: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let path: String
    var bytes: UInt64
}

struct LargeFileItem: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let bytes: UInt64
}

@MainActor
final class StorageManager: ObservableObject {
    @Published var cleanupCategories: [CleanupCategory] = []
    @Published var storageLocations: [StorageLocation] = []
    @Published var largeFiles: [LargeFileItem] = []
    @Published var installedApplications: [InstalledApplication] = []
    @Published var isScanningCleanup = false
    @Published var isScanningStorageUsage = false
    @Published var isScanningApplications = false
    @Published var isCleaning = false
    @Published var uninstallingAppID: String?
    @Published var cleanupMessage: String?
    @Published var uninstallMessage: String?
    @Published var diskUsed: UInt64 = 0
    @Published var diskTotal: UInt64 = 0
    @Published var diskAvailable: UInt64 = 0

    private let worker = DispatchQueue(label: "local.mac-resource-monitor.storage", qos: .userInitiated)
    private let analysisWorker = DispatchQueue(label: "local.mac-resource-monitor.storage-analysis", qos: .userInitiated)

    var selectedCleanupBytes: UInt64 {
        cleanupCategories.filter(\.isSelected).reduce(0) { $0 + $1.bytes }
    }

    var containsSelectedTrash: Bool {
        cleanupCategories.contains { $0.kind == .trash && $0.isSelected }
    }

    func scanCleanup() {
        guard !isScanningCleanup, !isCleaning else { return }
        isScanningCleanup = true
        cleanupMessage = nil
        let disk = Self.diskUsage()
        diskUsed = disk.used
        diskTotal = disk.total
        diskAvailable = disk.available
        let previousSelection = Dictionary(uniqueKeysWithValues: cleanupCategories.map { ($0.kind, $0.isSelected) })

        worker.async { [weak self] in
            let categories = Self.cleanupDefinitions().map { definition -> CleanupCategory in
                let size = Self.directoryStats(atPath: definition.path)
                var result = definition
                result.bytes = size.bytes
                result.itemCount = size.items
                if let selected = previousSelection[definition.kind] {
                    result.isSelected = selected
                }
                return result
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupCategories = categories
                self.isScanningCleanup = false
            }
        }
    }

    func toggleCategory(_ category: CleanupCategory) {
        guard let index = cleanupCategories.firstIndex(where: { $0.id == category.id }) else { return }
        cleanupCategories[index].isSelected.toggle()
    }

    func scanStorageUsage() {
        guard !isScanningStorageUsage else { return }
        isScanningStorageUsage = true
        let disk = Self.diskUsage()
        diskUsed = disk.used
        diskTotal = disk.total
        diskAvailable = disk.available

        analysisWorker.async { [weak self] in
            let locations = Self.storageUsageInventory()
            let files = Self.largeFileInventory()
            DispatchQueue.main.async {
                guard let self else { return }
                self.storageLocations = locations
                self.largeFiles = files
                self.isScanningStorageUsage = false
            }
        }
    }

    func cleanSelected() {
        guard !isCleaning else { return }
        let selected = cleanupCategories.filter { $0.isSelected && $0.bytes > 0 }
        guard !selected.isEmpty else {
            cleanupMessage = "没有可清理的所选项目"
            return
        }
        isCleaning = true
        cleanupMessage = nil

        worker.async { [weak self] in
            var removedBytes: UInt64 = 0
            var failureCount = 0
            for category in selected {
                let result = Self.cleanContents(of: category)
                removedBytes += result.removedBytes
                failureCount += result.failures
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaning = false
                if failureCount == 0 {
                    self.cleanupMessage = "已清理 \(storageFormatBytes(removedBytes))"
                } else {
                    self.cleanupMessage = "已清理 \(storageFormatBytes(removedBytes))，\(failureCount) 项因正在使用或权限不足而保留"
                }
                self.scanCleanup()
            }
        }
    }

    func scanApplications() {
        guard !isScanningApplications, uninstallingAppID == nil else { return }
        isScanningApplications = true
        uninstallMessage = nil

        worker.async { [weak self] in
            let applications = Self.applicationInventory()
            DispatchQueue.main.async {
                guard let self else { return }
                self.installedApplications = applications
                self.isScanningApplications = false
            }
        }
    }

    func uninstall(_ application: InstalledApplication) {
        guard uninstallingAppID == nil else { return }
        uninstallingAppID = application.id
        uninstallMessage = nil

        worker.async { [weak self] in
            let result = Self.moveApplicationAndResidueToTrash(application)
            DispatchQueue.main.async {
                guard let self else { return }
                self.uninstallingAppID = nil
                switch result {
                case .success(let residueCount):
                    let suffix = residueCount > 0 ? "，并处理了 \(residueCount) 项 Bundle ID 残留" : ""
                    self.uninstallMessage = "“\(application.name)”已移入废纸篓\(suffix)。清空废纸篓后释放空间。"
                    self.installedApplications.removeAll { $0.id == application.id }
                case .failure(let error):
                    self.uninstallMessage = "无法卸载“\(application.name)”：\(error.localizedDescription)"
                }
            }
        }
    }

    func reveal(_ application: InstalledApplication) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: application.path)])
    }

    func revealStoragePath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    nonisolated static func diskUsage() -> (used: UInt64, total: UInt64, available: UInt64) {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else { return (0, 0, 0) }
        let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
        let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)))
        return (total >= available ? total - available : 0, total, available)
    }

    private nonisolated static func cleanupDefinitions() -> [CleanupCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            CleanupCategory(
                kind: .caches,
                title: "应用缓存",
                detail: "可重新生成的用户缓存；保留本程序的硬件检测组件",
                symbol: "shippingbox",
                path: "\(home)/Library/Caches",
                bytes: 0,
                itemCount: 0,
                isSelected: true,
                isIrreversible: false
            ),
            CleanupCategory(
                kind: .logs,
                title: "日志与崩溃报告",
                detail: "用户级应用日志和诊断报告，不包含系统日志",
                symbol: "doc.text.magnifyingglass",
                path: "\(home)/Library/Logs",
                bytes: 0,
                itemCount: 0,
                isSelected: true,
                isIrreversible: false
            ),
            CleanupCategory(
                kind: .xcodeDerivedData,
                title: "Xcode 构建缓存",
                detail: "DerivedData；下次构建时会重新生成",
                symbol: "hammer",
                path: "\(home)/Library/Developer/Xcode/DerivedData",
                bytes: 0,
                itemCount: 0,
                isSelected: false,
                isIrreversible: false
            ),
            CleanupCategory(
                kind: .trash,
                title: "废纸篓",
                detail: "清空后无法从废纸篓恢复，默认不选择",
                symbol: "trash",
                path: "\(home)/.Trash",
                bytes: 0,
                itemCount: 0,
                isSelected: false,
                isIrreversible: true
            )
        ]
    }

    private nonisolated static func storageLocationDefinitions() -> [StorageLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var results = [
            StorageLocation(id: "/Applications", title: "应用程序", detail: "/Applications", symbol: "square.grid.2x2", path: "/Applications", bytes: 0)
        ]

        let homeNames: [String: (String, String)] = [
            "Downloads": ("下载", "下载的安装包、视频与其他文件"),
            "Documents": ("文稿", "文档与工作文件"),
            "Desktop": ("桌面", "桌面上的文件与文件夹"),
            "Movies": ("影片", "视频与媒体资料库"),
            "Pictures": ("图片", "照片图库与图片"),
            "Music": ("音乐", "音乐与音频资料库"),
            "Applications": ("个人应用程序", "用户目录中的应用")
        ]
        for url in directoryChildren(of: home) where url.lastPathComponent != "Library" && url.lastPathComponent != ".Trash" {
            let localized = homeNames[url.lastPathComponent]
            results.append(StorageLocation(
                id: url.path,
                title: localized?.0 ?? url.lastPathComponent,
                detail: localized?.1 ?? "个人目录",
                symbol: symbolForStoragePath(url.path),
                path: url.path,
                bytes: 0
            ))
        }

        let expandedLibraryFolders: [(String, String)] = [
            ("Application Support", "应用数据"),
            ("Containers", "应用容器"),
            ("Group Containers", "共享应用容器"),
            ("Developer", "开发工具数据")
        ]
        let expandedNames = Set(expandedLibraryFolders.map(\.0))
        for url in directoryChildren(of: library) where !expandedNames.contains(url.lastPathComponent) {
            results.append(StorageLocation(
                id: url.path,
                title: libraryTitle(for: url.lastPathComponent),
                detail: "Library/\(url.lastPathComponent)",
                symbol: symbolForStoragePath(url.path),
                path: url.path,
                bytes: 0
            ))
        }

        for (folder, groupTitle) in expandedLibraryFolders {
            let root = library.appendingPathComponent(folder, isDirectory: true)
            for url in directoryChildren(of: root) {
                results.append(StorageLocation(
                    id: url.path,
                    title: url.lastPathComponent,
                    detail: "\(groupTitle) · \(folder)",
                    symbol: symbolForStoragePath(url.path),
                    path: url.path,
                    bytes: 0
                ))
            }
        }
        return results
    }

    private nonisolated static func directoryChildren(of root: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private nonisolated static func libraryTitle(for name: String) -> String {
        switch name {
        case "Caches": return "应用缓存"
        case "Mobile Documents": return "iCloud Drive 本地数据"
        case "CloudStorage": return "云盘本地数据"
        case "Mail": return "邮件数据"
        case "Messages": return "信息附件与数据"
        case "Photos": return "照片数据"
        case "Parallels": return "Parallels 数据"
        default: return name
        }
    }

    private nonisolated static func symbolForStoragePath(_ path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("download") { return "arrow.down.circle" }
        if lower.contains("picture") || lower.contains("photo") { return "photo" }
        if lower.contains("movie") || lower.contains("video") { return "film" }
        if lower.contains("music") { return "music.note" }
        if lower.contains("cache") { return "archivebox" }
        if lower.contains("icloud") || lower.contains("cloud") { return "icloud" }
        if lower.contains("developer") || lower.contains("xcode") { return "hammer" }
        if lower.contains("container") { return "shippingbox" }
        return "folder.fill"
    }

    private nonisolated static func storageUsageInventory() -> [StorageLocation] {
        var definitions = storageLocationDefinitions().filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let sizes = directorySizes(atPaths: definitions.map(\.path))
        for index in definitions.indices {
            definitions[index].bytes = sizes[definitions[index].path] ?? 0
        }
        return definitions
            .filter { $0.bytes > 0 }
            .sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            .prefix(250)
            .map { $0 }
    }

    private nonisolated static func directorySizes(atPaths paths: [String]) -> [String: UInt64] {
        guard !paths.isEmpty else { return [:] }
        guard let command = CommandRunner.run(
            "/usr/bin/du",
            arguments: ["-sk"] + paths,
            timeout: 120
        ) else { return [:] }
        let output = command.outputString
        var result: [String: UInt64] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2, let blocks = UInt64(fields[0]) else { continue }
            result[String(fields[1])] = blocks * 1024
        }
        return result
    }

    private nonisolated static func largeFileInventory() -> [LargeFileItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard let command = CommandRunner.run(
            "/usr/bin/mdfind",
            arguments: ["-onlyin", home.path, "kMDItemFSSize >= 524288000"],
            timeout: 20
        ) else { return [] }
        let output = command.outputString
        var seen = Set<String>()
        var files: [LargeFileItem] = []
        for line in output.split(separator: "\n") {
            let url = URL(fileURLWithPath: String(line)).standardizedFileURL
            guard url.path.hasPrefix(home.path + "/"), seen.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            let byteCount = max(values.totalFileAllocatedSize ?? 0, values.fileSize ?? 0)
            guard byteCount >= 524_288_000 else { continue }
            files.append(LargeFileItem(
                id: url.path,
                name: url.lastPathComponent,
                path: url.path,
                bytes: UInt64(byteCount)
            ))
        }
        return files.sorted { $0.bytes > $1.bytes }.prefix(20).map { $0 }
    }

    private nonisolated static func directoryStats(atPath path: String) -> (bytes: UInt64, items: Int) {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return (0, 0) }
        guard let command = CommandRunner.run(
            "/usr/bin/du",
            arguments: ["-sk", root.path],
            timeout: 60
        ) else { return (0, 0) }
        let output = command.outputString
        let blocks = UInt64(output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "0") ?? 0
        var bytes = blocks * 1024
        if path.hasSuffix("/Library/Caches") {
            let protectedCache = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Caches/\(Bundle.main.bundleIdentifier ?? "io.github.svsvnm.MacResourceMonitor")"
                )
            if protectedCache.standardizedFileURL.path != root.standardizedFileURL.path {
                let protectedBytes = directoryStats(atPath: protectedCache.path).bytes
                bytes = bytes >= protectedBytes ? bytes - protectedBytes : 0
            }
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.count ?? 1
        return (bytes, children)
    }

    private nonisolated static func cleanContents(of category: CleanupCategory) -> (removedBytes: UInt64, failures: Int) {
        let root = URL(fileURLWithPath: category.path, isDirectory: true).standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let allowedRoots = cleanupDefinitions().map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        guard root.path.hasPrefix(home + "/"), allowedRoots.contains(root.path) else {
            return (0, 1)
        }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return (0, 1) }

        let protectedCache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/\(Bundle.main.bundleIdentifier ?? "io.github.svsvnm.MacResourceMonitor")"
            )
            .standardizedFileURL.path
        var removedBytes: UInt64 = 0
        var failures = 0
        for child in children {
            if child.standardizedFileURL.path == protectedCache { continue }
            let stats = directoryStats(atPath: child.path)
            do {
                try FileManager.default.removeItem(at: child)
                removedBytes += stats.bytes
            } catch {
                failures += 1
            }
        }
        return (removedBytes, failures)
    }

    private nonisolated static func applicationInventory() -> [InstalledApplication] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var applications: [InstalledApplication] = []

        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    continue
                }
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                let bundle = Bundle(url: url)
                let identifier = bundle?.bundleIdentifier
                guard identifier != currentBundleIdentifier else { continue }
                let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                    ?? "--"
                let size = directoryStats(atPath: url.path).bytes
                applications.append(InstalledApplication(
                    id: canonical,
                    name: name,
                    version: version,
                    bundleIdentifier: identifier,
                    path: canonical,
                    bytes: size,
                    needsAdministrator: !FileManager.default.isWritableFile(atPath: canonical)
                ))
            }
        }
        return applications.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private nonisolated static func verifiedResidueURLs(for application: InstalledApplication) -> [URL] {
        guard let bundleID = validatedBundleIdentifier(application.bundleIdentifier),
              bundleID != Bundle.main.bundleIdentifier else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let relativePaths = [
            "Library/Application Support/\(bundleID)",
            "Library/Caches/\(bundleID)",
            "Library/Preferences/\(bundleID).plist",
            "Library/Saved Application State/\(bundleID).savedState",
            "Library/HTTPStorages/\(bundleID)",
            "Library/WebKit/\(bundleID)",
            "Library/Containers/\(bundleID)",
            "Library/Application Scripts/\(bundleID)",
            "Library/Logs/\(bundleID)",
            "Library/LaunchAgents/\(bundleID).plist"
        ]
        return relativePaths
            .map { home.appendingPathComponent($0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated static func validatedBundleIdentifier(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count <= 255 else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy {
                      $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                  }
              }) else { return nil }
        return value
    }

    private nonisolated static func moveApplicationAndResidueToTrash(
        _ application: InstalledApplication
    ) -> Result<Int, Error> {
        let appURL = URL(fileURLWithPath: application.path).standardizedFileURL
        let allowedRoots = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"]
        guard appURL.pathExtension.lowercased() == "app",
              allowedRoots.contains(where: { appURL.path.hasPrefix($0) }),
              appURL.path != Bundle.main.bundleURL.standardizedFileURL.path else {
            return .failure(StorageOperationError.invalidApplicationPath)
        }

        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: appURL, resultingItemURL: &trashedURL)
        } catch {
            return .failure(error)
        }

        var residueCount = 0
        for residue in verifiedResidueURLs(for: application) {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: residue, resultingItemURL: &trashedURL)
                residueCount += 1
            } catch {
                continue
            }
        }
        return .success(residueCount)
    }
}

private enum StorageOperationError: LocalizedError {
    case invalidApplicationPath

    var errorDescription: String? {
        switch self {
        case .invalidApplicationPath: return "应用路径未通过安全检查"
        }
    }
}

enum StoragePage: String {
    case overview
    case usage
    case largeFiles
    case cleanup
}

struct StorageCleanupView: View {
    @ObservedObject var model: StorageManager
    @Binding var selectedPage: StoragePage
    @State private var showCleanupConfirmation = false

    private let navigationColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if selectedPage == .overview {
                storageHome
            } else {
                secondaryHeader
                switch selectedPage {
                case .overview:
                    EmptyView()
                case .usage:
                    storageUsagePage
                case .largeFiles:
                    largeFilesPage
                case .cleanup:
                    cleanupPage
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedPage)
        .task {
            if model.cleanupCategories.isEmpty { model.scanCleanup() }
            if model.storageLocations.isEmpty { model.scanStorageUsage() }
        }
        .confirmationDialog(
            model.containsSelectedTrash ? "确认永久清理（包含废纸篓）？" : "确认清理所选缓存？",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("永久删除 \(storageFormatBytes(model.selectedCleanupBytes))", role: .destructive) {
                model.cleanSelected()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text(model.containsSelectedTrash
                 ? "废纸篓内容删除后无法恢复。缓存和日志会在需要时由应用重新生成。"
                 : "所选缓存和日志会被永久删除，并在应用需要时重新生成。")
        }
    }

    private var storageHome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择一个存储任务")
                        .font(.system(size: 17, weight: .semibold))
                    Text("先查看，再决定。详细结果分别位于独立页面。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("3 个工具")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 3)

            LazyVGrid(columns: navigationColumns, spacing: 14) {
                navigationCard(
                    page: .usage,
                    title: "空间占用",
                    subtitle: "查看主要目录与分类排行",
                    value: usageSummary,
                    detail: model.isScanningStorageUsage ? "正在分析本机目录" : "\(model.storageLocations.count) 个已识别区域",
                    symbol: "chart.bar.xaxis",
                    color: .orange
                )
                navigationCard(
                    page: .largeFiles,
                    title: "大文件",
                    subtitle: "定位 500 MB 以上的文件",
                    value: largeFilesSummary,
                    detail: model.isScanningStorageUsage ? "正在查询 Spotlight" : "\(model.largeFiles.count) 个索引结果",
                    symbol: "doc.text.magnifyingglass",
                    color: .blue
                )
                navigationCard(
                    page: .cleanup,
                    title: "安全清理",
                    subtitle: "清理可重新生成的数据",
                    value: cleanupSummary,
                    detail: model.isScanningCleanup ? "正在计算可清理空间" : "\(model.cleanupCategories.count) 类明确项目",
                    symbol: "sparkles",
                    color: .purple
                )
            }

            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("默认只读，清理前再次确认")
                        .font(.system(size: 12, weight: .semibold))
                    Text("文稿、照片、下载和其他个人文件不会被自动删除。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(15)
            .glassCard(cornerRadius: 18)
        }
    }

    private func navigationCard(
        page: StoragePage,
        title: String,
        subtitle: String,
        value: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        Button {
            selectedPage = page
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(color.opacity(0.16))
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    .frame(width: 42, height: 42)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 28, height: 28)
                        .background(color.opacity(0.10), in: Circle())
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                Text(value)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(17)
            .frame(maxWidth: .infinity, minHeight: 198, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: InterfaceMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .clear.tint(color.opacity(0.065)).interactive(),
            in: RoundedRectangle(cornerRadius: InterfaceMetrics.cardRadius, style: .continuous)
        )
        .shadow(color: Color.black.opacity(0.035), radius: 14, y: 6)
    }

    private var usageSummary: String {
        guard !model.isScanningStorageUsage else { return "分析中…" }
        guard let largest = model.storageLocations.first else { return "待扫描" }
        return storageFormatBytes(largest.bytes)
    }

    private var largeFilesSummary: String {
        guard !model.isScanningStorageUsage else { return "查询中…" }
        let total = model.largeFiles.reduce(UInt64(0)) { $0 + $1.bytes }
        return total > 0 ? storageFormatBytes(total) : "未发现"
    }

    private var cleanupSummary: String {
        guard !model.isScanningCleanup else { return "计算中…" }
        let total = model.cleanupCategories.reduce(UInt64(0)) { $0 + $1.bytes }
        return total > 0 ? storageFormatBytes(total) : "无需清理"
    }

    private var secondaryHeader: some View {
        HStack(spacing: 14) {
            Button {
                selectedPage = .overview
            } label: {
                Label("存储首页", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)

            Divider()
                .frame(height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(pageTitle)
                    .font(.system(size: 20, weight: .semibold))
                Text(pageSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(15)
        .glassCard(cornerRadius: 18)
    }

    private var pageTitle: String {
        switch selectedPage {
        case .overview: return "存储首页"
        case .usage: return "空间占用"
        case .largeFiles: return "大文件"
        case .cleanup: return "安全清理"
        }
    }

    private var pageSubtitle: String {
        switch selectedPage {
        case .overview: return "存储工具总览"
        case .usage: return "按实际大小查看主要目录和分类"
        case .largeFiles: return "使用 Spotlight 定位 500 MB 以上文件"
        case .cleanup: return "仅处理明确且可重新生成的用户数据"
        }
    }

    private var diskOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Macintosh HD", systemImage: "internaldrive.fill")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("已用 \(storageFormatBytes(model.diskUsed)) / \(storageFormatBytes(model.diskTotal))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let ratio = model.diskTotal > 0 ? Double(model.diskUsed) / Double(model.diskTotal) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule().fill(Color.orange.gradient)
                        .frame(width: geometry.size.width * min(1, max(0, ratio)))
                }
            }
            .frame(height: 9)
            Text("可用空间 \(storageFormatBytes(model.diskAvailable))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .glassCard(cornerRadius: 20)
    }

    private var storageUsagePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.storageLocations.isEmpty && model.isScanningStorageUsage {
                ProgressView("正在统计主要目录…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.storageLocations) { location in
                        storageLocationRow(location)
                    }
                }
            }

            Text("只读展示 · 受 macOS 隐私保护或尚未下载的云端内容可能无法统计，结果不等同于磁盘总占用。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var largeFilesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Spotlight 索引结果", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("最多显示 20 项")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if model.largeFiles.isEmpty {
                Text(model.isScanningStorageUsage ? "正在查找大文件…" : "未发现已被索引的 500 MB 以上文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .glassCard(cornerRadius: 18)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.largeFiles) { file in
                        largeFileRow(file)
                    }
                }
            }

            Text("大文件仅用于定位，不会进入一键清理范围。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var cleanupPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isScanningCleanup && model.cleanupCategories.isEmpty {
                ProgressView("正在统计可安全清理的空间…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(model.cleanupCategories) { category in
                        cleanupRow(category)
                    }
                }
            }

            HStack {
                if let message = model.cleanupMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Text("不会扫描或删除文档、照片、下载内容和其他个人文件。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("已选择 \(storageFormatBytes(model.selectedCleanupBytes))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Button(role: .destructive) {
                    showCleanupConfirmation = true
                } label: {
                    Label(model.isCleaning ? "清理中" : "清理所选项目", systemImage: "sparkles")
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(model.isCleaning || model.selectedCleanupBytes == 0)
            }
        }
    }

    private func storageLocationRow(_ location: StorageLocation) -> some View {
        HStack(spacing: 13) {
            managementListSymbol(location.symbol, color: .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(location.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(location.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(storageFormatBytes(location.bytes))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 90, alignment: .trailing)
            Button("在 Finder 中显示") { model.revealStoragePath(location.path) }
                .buttonStyle(.glass)
        }
        .padding(13)
        .stableListCard(cornerRadius: 16)
    }

    private func largeFileRow(_ file: LargeFileItem) -> some View {
        HStack(spacing: 13) {
            managementListSymbol("doc.fill", color: .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(file.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(storageFormatBytes(file.bytes))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 90, alignment: .trailing)
            Button("在 Finder 中显示") { model.revealStoragePath(file.path) }
                .buttonStyle(.glass)
        }
        .padding(13)
        .stableListCard(cornerRadius: 16)
    }

    private func cleanupRow(_ category: CleanupCategory) -> some View {
        Button {
            model.toggleCategory(category)
        } label: {
            HStack(spacing: 13) {
                ZStack(alignment: .bottomTrailing) {
                    managementListSymbol(
                        category.symbol,
                        color: category.isIrreversible ? .red : .purple
                    )
                    Image(systemName: category.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(category.isSelected ? Color.blue : Color.secondary)
                        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                        .offset(x: 3, y: 3)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(category.title).font(.system(size: 13, weight: .medium))
                        if category.isIrreversible {
                            Text("不可恢复")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.12), in: Capsule())
                                .foregroundStyle(.red)
                        }
                    }
                    Text(category.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(storageFormatBytes(category.bytes))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("\(category.itemCount) 个顶层项目")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .stableListCard(cornerRadius: 16)
    }

    private func managementListSymbol(_ symbol: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(color.opacity(0.12))
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 42, height: 42)
    }
}

struct AppUninstallerView: View {
    @ObservedObject var model: StorageManager
    @State private var query = ""
    @State private var pendingApplication: InstalledApplication?

    private var filteredApplications: [InstalledApplication] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return model.installedApplications
        }
        return model.installedApplications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已安装应用")
                        .font(.system(size: 17, weight: .semibold))
                    Text("按占用排序 · 卸载内容移入废纸篓，可恢复")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索应用或 Bundle ID", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .frame(width: 250)
                    .glassEffect(.regular, in: Capsule())
            }

            if let message = model.uninstallMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(message.hasPrefix("无法") ? Color.orange : Color.green)
                    .padding(.horizontal, 2)
            }

            if model.isScanningApplications && model.installedApplications.isEmpty {
                ProgressView("正在统计应用占用空间…")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(filteredApplications) { application in
                        applicationRow(application)
                    }
                }
            }

            Text("系统应用和“Mac资源监控”自身已排除；不会按模糊名称删除文件，也不会重置全局系统设置。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .task {
            if model.installedApplications.isEmpty { model.scanApplications() }
        }
        .alert(
            "确认卸载“\(pendingApplication?.name ?? "应用")”？",
            isPresented: Binding(
                get: { pendingApplication != nil },
                set: { if !$0 { pendingApplication = nil } }
            ),
            presenting: pendingApplication
        ) { application in
            Button("移入废纸篓", role: .destructive) {
                model.uninstall(application)
                pendingApplication = nil
            }
            Button("取消", role: .cancel) { pendingApplication = nil }
        } message: { application in
            Text("将移动应用本体及可用 Bundle ID 精确确认的用户缓存、偏好和容器。不会清空废纸篓；需要管理员权限的应用可能由 macOS 拒绝。")
        }
    }

    private func applicationRow(_ application: InstalledApplication) -> some View {
        HStack(spacing: 13) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(application.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("v\(application.version)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    if application.needsAdministrator {
                        Label("可能需要管理员权限", systemImage: "lock.fill")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                Text(application.bundleIdentifier ?? "未提供 Bundle ID")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(application.path)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text(storageFormatBytes(application.bytes))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(width: 90, alignment: .trailing)
            Button("在 Finder 中显示") { model.reveal(application) }
                .buttonStyle(.glass)
            Button(role: .destructive) {
                pendingApplication = application
            } label: {
                if model.uninstallingAppID == application.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text("卸载")
                }
            }
            .buttonStyle(.glass)
            .disabled(model.uninstallingAppID != nil)
        }
        .padding(13)
        .stableListCard(cornerRadius: 16)
    }
}

private func storageFormatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}
