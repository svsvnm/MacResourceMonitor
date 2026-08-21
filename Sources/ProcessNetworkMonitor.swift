import Foundation
import SwiftUI
import AppKit
import Darwin

struct ProcessTrafficRow: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let sessionDownloadedBytes: UInt64
    let sessionUploadedBytes: UInt64

    var id: Int32 { pid }
    var currentBytesPerSecond: Double { downloadBytesPerSecond + uploadBytesPerSecond }
    var sessionBytes: UInt64 { sessionDownloadedBytes + sessionUploadedBytes }
}

private struct ProcessTrafficDelta {
    let pid: Int32
    let name: String
    let downloadedBytes: UInt64
    let uploadedBytes: UInt64
}

private enum ProcessTrafficCollectionResult {
    case success(rows: [ProcessTrafficDelta], duration: TimeInterval)
    case failure(String)
}

private enum ProcessTrafficCollector {
    private static let sampleInterval: TimeInterval = 1
    private static let sampleCount = 3

    static func collect() -> ProcessTrafficCollectionResult {
        guard let result = CommandRunner.run(
            "/usr/bin/nettop",
            arguments: [
                "-P", "-n", "-x", "-d", "-c",
                "-t", "external",
                "-L", String(sampleCount),
                "-s", String(Int(sampleInterval)),
                "-J", "bytes_in,bytes_out"
            ],
            timeout: 5
        ) else {
            return .failure("无法启动 macOS nettop")
        }

        if result.timedOut {
            return .failure("进程流量采样超时")
        }
        guard result.terminationStatus == 0 else {
            let detail = result.errorString.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(detail.isEmpty ? "nettop 返回错误 \(result.terminationStatus)" : detail)
        }

        let samples = parseSamples(result.outputString)
        guard samples.count >= 2 else {
            return .failure("nettop 未返回足够的流量样本")
        }

        // Delta mode's first block is cumulative because no previous sample exists.
        // Only subsequent blocks represent traffic during the requested interval.
        let deltaSamples = samples.dropFirst()
        var aggregated: [Int32: ProcessTrafficDelta] = [:]
        for sample in deltaSamples {
            for row in sample {
                let previous = aggregated[row.pid]
                aggregated[row.pid] = ProcessTrafficDelta(
                    pid: row.pid,
                    name: resolvedProcessName(pid: row.pid, fallback: previous?.name ?? row.name),
                    downloadedBytes: (previous?.downloadedBytes ?? 0) + row.downloadedBytes,
                    uploadedBytes: (previous?.uploadedBytes ?? 0) + row.uploadedBytes
                )
            }
        }

        return .success(
            rows: Array(aggregated.values),
            duration: Double(deltaSamples.count) * sampleInterval
        )
    }

    private static func parseSamples(_ output: String) -> [[ProcessTrafficDelta]] {
        var samples: [[ProcessTrafficDelta]] = []
        var current: [ProcessTrafficDelta]?

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let fields = parseCSVLine(String(rawLine))
            guard fields.count >= 3 else { continue }

            if fields[1] == "bytes_in", fields[2] == "bytes_out" {
                if let current { samples.append(current) }
                current = []
                continue
            }

            guard current != nil,
                  let identity = parseIdentity(fields[0]),
                  let downloaded = UInt64(fields[1]),
                  let uploaded = UInt64(fields[2]) else { continue }

            current?.append(ProcessTrafficDelta(
                pid: identity.pid,
                name: identity.name,
                downloadedBytes: downloaded,
                uploadedBytes: uploaded
            ))
        }

        if let current { samples.append(current) }
        return samples
    }

    private static func parseIdentity(_ value: String) -> (name: String, pid: Int32)? {
        guard let separator = value.lastIndex(of: "."),
              let pid = Int32(value[value.index(after: separator)...]) else { return nil }
        let name = String(value[..<separator]).trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "未知进程" : name, pid)
    }

    private static func resolvedProcessName(pid: Int32, fallback: String) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return fallback }
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if isQuoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = line.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
    }
}

final class ProcessNetworkMonitor: ObservableObject {
    @Published private(set) var rows: [ProcessTrafficRow] = []
    @Published private(set) var downloadBytesPerSecond = 0.0
    @Published private(set) var uploadBytesPerSecond = 0.0
    @Published private(set) var sessionDownloadedBytes: UInt64 = 0
    @Published private(set) var sessionUploadedBytes: UInt64 = 0
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var errorText: String?
    @Published private(set) var isCollecting = true

    private struct SessionEntry {
        var name: String
        var downloadedBytes: UInt64
        var uploadedBytes: UInt64
        var lastSeen: Date
    }

    private let queue = DispatchQueue(label: "local.mac-resource-monitor.process-network", qos: .utility)
    private var sessionEntries: [Int32: SessionEntry] = [:]

    init() {
        scheduleCollection()
    }

    func resetSessionTotals() {
        sessionEntries.removeAll()
        sessionDownloadedBytes = 0
        sessionUploadedBytes = 0
        rows = rows.map {
            ProcessTrafficRow(
                pid: $0.pid,
                name: $0.name,
                downloadBytesPerSecond: $0.downloadBytesPerSecond,
                uploadBytesPerSecond: $0.uploadBytesPerSecond,
                sessionDownloadedBytes: 0,
                sessionUploadedBytes: 0
            )
        }
    }

    private func scheduleCollection() {
        queue.async { [weak self] in
            let result = ProcessTrafficCollector.collect()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apply(result)
                self.queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.scheduleCollection()
                }
            }
        }
    }

    private func apply(_ result: ProcessTrafficCollectionResult) {
        switch result {
        case let .failure(message):
            errorText = message
            isCollecting = false

        case let .success(deltas, duration):
            let now = Date()
            let safeDuration = max(0.1, duration)
            let activePIDs = Set(deltas.map(\.pid))
            var liveRates: [Int32: (download: Double, upload: Double)] = [:]

            for delta in deltas {
                let current = sessionEntries[delta.pid]
                sessionEntries[delta.pid] = SessionEntry(
                    name: delta.name,
                    downloadedBytes: (current?.downloadedBytes ?? 0) + delta.downloadedBytes,
                    uploadedBytes: (current?.uploadedBytes ?? 0) + delta.uploadedBytes,
                    lastSeen: now
                )
                liveRates[delta.pid] = (
                    Double(delta.downloadedBytes) / safeDuration,
                    Double(delta.uploadedBytes) / safeDuration
                )
            }

            sessionEntries = sessionEntries.filter { pid, entry in
                activePIDs.contains(pid) || now.timeIntervalSince(entry.lastSeen) < 120
            }

            let nextRows = sessionEntries.map { pid, entry in
                let rate = liveRates[pid] ?? (0, 0)
                return ProcessTrafficRow(
                    pid: pid,
                    name: entry.name,
                    downloadBytesPerSecond: rate.download,
                    uploadBytesPerSecond: rate.upload,
                    sessionDownloadedBytes: entry.downloadedBytes,
                    sessionUploadedBytes: entry.uploadedBytes
                )
            }
            .sorted {
                if $0.currentBytesPerSecond != $1.currentBytesPerSecond {
                    return $0.currentBytesPerSecond > $1.currentBytesPerSecond
                }
                return $0.sessionBytes > $1.sessionBytes
            }
            .prefix(100)

            rows = Array(nextRows)
            downloadBytesPerSecond = liveRates.values.reduce(0) { $0 + $1.download }
            uploadBytesPerSecond = liveRates.values.reduce(0) { $0 + $1.upload }
            sessionDownloadedBytes = sessionEntries.values.reduce(0) { $0 + $1.downloadedBytes }
            sessionUploadedBytes = sessionEntries.values.reduce(0) { $0 + $1.uploadedBytes }
            lastUpdatedAt = now
            errorText = nil
            isCollecting = false
        }
    }
}

private enum ProcessTrafficSort: String, CaseIterable, Identifiable {
    case current = "当前流速"
    case download = "下载"
    case upload = "上传"
    case session = "累计"

    var id: String { rawValue }
}

struct ProcessTrafficView: View {
    @ObservedObject var model: ProcessNetworkMonitor
    @State private var searchText = ""
    @State private var sort: ProcessTrafficSort = .current

    private var visibleRows: [ProcessTrafficRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = model.rows.filter { row in
            query.isEmpty || row.name.localizedCaseInsensitiveContains(query) || String(row.pid).contains(query)
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .current: return lhs.currentBytesPerSecond > rhs.currentBytesPerSecond
            case .download: return lhs.downloadBytesPerSecond > rhs.downloadBytesPerSecond
            case .upload: return lhs.uploadBytesPerSecond > rhs.uploadBytesPerSecond
            case .session: return lhs.sessionBytes > rhs.sessionBytes
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("流量概览", subtitle: "外部网络接口 · 约每 2 秒更新")

            HStack(spacing: 12) {
                summaryCard(
                    title: "当前下载",
                    value: processTrafficRate(model.downloadBytesPerSecond),
                    detail: "所有进程合计",
                    symbol: "arrow.down",
                    color: .green
                )
                summaryCard(
                    title: "当前上传",
                    value: processTrafficRate(model.uploadBytesPerSecond),
                    detail: "所有进程合计",
                    symbol: "arrow.up",
                    color: .blue
                )
                summaryCard(
                    title: "本次监控累计",
                    value: processTrafficBytes(model.sessionDownloadedBytes + model.sessionUploadedBytes),
                    detail: "↓ \(processTrafficBytes(model.sessionDownloadedBytes)) · ↑ \(processTrafficBytes(model.sessionUploadedBytes))",
                    symbol: "sum",
                    color: .purple
                )
            }

            sectionLabel("进程排行", subtitle: "显示最近活跃和本次监控产生流量的进程")

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索进程名或 PID", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                Picker("排序", selection: $sort) {
                    ForEach(ProcessTrafficSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
            .padding(14)
            .stableDashboardCard(cornerRadius: 18)

            if let error = model.errorText {
                statusCard(symbol: "exclamationmark.triangle.fill", title: "暂时无法读取进程流量", detail: error, color: .orange)
            } else if model.lastUpdatedAt == nil {
                statusCard(symbol: "network", title: "正在建立进程流量基线", detail: "首次结果大约需要 2 秒", color: .blue)
            } else if visibleRows.isEmpty {
                statusCard(symbol: "checkmark.circle.fill", title: "当前没有匹配的进程流量", detail: "尝试清除搜索条件或产生一些网络活动", color: .green)
            } else {
                processTable
            }

            Label(
                "只读调用 macOS nettop；不查看通信内容，不记录域名，不接管连接，并排除本机回环流量。累计值从本次应用启动或手动清零后开始。",
                systemImage: "lock.shield"
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var processTable: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("下载").frame(width: 112, alignment: .trailing)
                Text("上传").frame(width: 112, alignment: .trailing)
                Text("本次累计").frame(width: 112, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)

            LazyVStack(spacing: 8) {
                ForEach(Array(visibleRows.prefix(80).enumerated()), id: \.element.id) { index, row in
                    processRow(row, rank: index + 1)
                }
            }
        }
    }

    private func processRow(_ row: ProcessTrafficRow, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            processIcon(pid: row.pid, name: row.name)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("PID \(row.pid)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                GeometryReader { proxy in
                    let total = max(1, model.rows.first?.currentBytesPerSecond ?? 1)
                    Capsule()
                        .fill(Color.primary.opacity(0.055))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.green.opacity(0.65))
                                .frame(width: proxy.size.width * min(1, row.currentBytesPerSecond / total))
                        }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(processTrafficRate(row.downloadBytesPerSecond))
                .foregroundStyle(.green)
                .frame(width: 112, alignment: .trailing)
            Text(processTrafficRate(row.uploadBytesPerSecond))
                .foregroundStyle(.blue)
                .frame(width: 112, alignment: .trailing)
            Text(processTrafficBytes(row.sessionBytes))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .stableListCard(cornerRadius: 16)
    }

    @ViewBuilder
    private func processIcon(pid: Int32, name: String) -> some View {
        if let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(InterfacePalette.iconSurface)
                .overlay {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 30, height: 30)
        }
    }

    private func summaryCard(title: String, value: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.12))
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88)
        .stableDashboardCard()
    }

    private func statusCard(symbol: String, title: String, detail: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isCollecting { ProgressView().controlSize(.small) }
        }
        .padding(18)
        .stableListCard(cornerRadius: 18)
    }

    private func sectionLabel(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            if let date = model.lastUpdatedAt {
                Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private func processTrafficRate(_ bytesPerSecond: Double) -> String {
    "\(processTrafficBytes(UInt64(max(0, bytesPerSecond))))/s"
}

private func processTrafficBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}
