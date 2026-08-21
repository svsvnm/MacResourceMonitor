import SwiftUI
import Combine
import Darwin
import IOKit
import SystemConfiguration

private struct ProcessRow: Identifiable {
    let id: Int32
    let name: String
    let cpu: Double
    let memoryBytes: UInt64
}

private struct ChargingPowerSnapshot {
    var externalConnected = false
    var isCharging = false
    var inputWatts: Double? = nil
    var batteryChargeWatts: Double? = nil
    var systemLoadWatts: Double? = nil
}

private struct ResourceSnapshot {
    var cpuPercent = 0.0
    var memoryPercent = 0.0
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskPercent = 0.0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var downloadBytesPerSecond = 0.0
    var uploadBytesPerSecond = 0.0
    var networkInterface = "--"
    var batteryText = "检测中"
    var batteryPercent: Double? = nil
    var powerSource = "--"
    var cpuTemperature: Double? = nil
    var hottestCPUTemperature: Double? = nil
    var fanSpeed: Double? = nil
    var fanCount = 0
    var thermalState = "正常"
    var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    var processes: [ProcessRow] = []
    var cableMonitor = CableMonitorSnapshot()
    var chargingPower = ChargingPowerSnapshot()
    var updatedAt = Date()
}

private final class ChargingPowerReader {
    func read() -> ChargingPowerSnapshot {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return ChargingPowerSnapshot() }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        }

        let externalConnected = (property("ExternalConnected") as? NSNumber)?.boolValue ?? false
        let isCharging = (property("IsCharging") as? NSNumber)?.boolValue ?? false
        let telemetry = property("PowerTelemetryData") as? [String: Any] ?? [:]

        func watts(_ key: String) -> Double? {
            guard let milliwatts = (telemetry[key] as? NSNumber)?.doubleValue,
                  milliwatts >= 0, milliwatts < 300_000 else { return nil }
            return milliwatts / 1000
        }

        return ChargingPowerSnapshot(
            externalConnected: externalConnected,
            isCharging: isCharging,
            inputWatts: externalConnected ? watts("SystemPowerIn") : nil,
            batteryChargeWatts: isCharging ? watts("BatteryPower") : nil,
            systemLoadWatts: watts("SystemLoad")
        )
    }
}

private enum SMCDataType: String {
    case ui8 = "ui8 "
    case ui16 = "ui16"
    case ui32 = "ui32"
    case sp78 = "sp78"
    case flt = "flt "
    case fpe2 = "fpe2"
}

private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuLimit: UInt32 = 0
        var gpuLimit: UInt32 = 0
        var memoryLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var limitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private final class SMCReader {
    private var connection: io_connect_t = 0

    private let m5CPUKeys = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
        "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
    ]

    init() {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator)
        guard result == kIOReturnSuccess else { return }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return }
        defer { IOObjectRelease(device) }
        guard IOServiceOpen(device, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
            connection = 0
            return
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func cpuTemperatures() -> (average: Double, hottest: Double)? {
        let values = m5CPUKeys.compactMap { value(for: $0) }.filter { $0 >= 10 && $0 <= 120 }
        guard !values.isEmpty, let hottest = values.max() else { return nil }
        return (values.reduce(0, +) / Double(values.count), hottest)
    }

    func fanReading() -> (speed: Double?, count: Int) {
        guard let rawCount = value(for: "FNum") else { return (nil, 0) }
        let count = max(0, Int(rawCount.rounded()))
        guard count > 0 else { return (nil, 0) }
        let speeds = (0..<count).compactMap { value(for: "F\($0)Ac") }.filter { $0 >= 0 && $0 < 20_000 }
        return (speeds.max(), count)
    }

    private func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func string(from code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff), UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func value(for key: String) -> Double? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = fourCharacterCode(key)
        input.data8 = 9

        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.keyInfo.dataSize > 0 else { return nil }
        let dataSize = Int(output.keyInfo.dataSize)
        let dataType = string(from: output.keyInfo.dataType)

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(dataSize)) }
        guard !bytes.isEmpty else { return nil }
        switch dataType {
        case SMCDataType.ui8.rawValue:
            return Double(bytes[0])
        case SMCDataType.ui16.rawValue where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case SMCDataType.ui32.rawValue where bytes.count >= 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case SMCDataType.sp78.rawValue where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case SMCDataType.fpe2.rawValue where bytes.count >= 2:
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case SMCDataType.flt.rawValue where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        default:
            return nil
        }
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, 2, &input, inputSize, &output, &outputSize)
    }
}

private final class SystemCollector {
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var previousNetwork: (received: UInt64, sent: UInt64, date: Date)?
    private var cachedBattery: (text: String, percent: Double?, source: String) = ("检测中", nil, "--")
    private var batterySampleCounter = 0
    private var cableSampleCounter = 0
    private var cachedCableMonitor = CableMonitorSnapshot()
    private let smc = SMCReader()
    private let cableCollector = CableCollector()
    private let chargingPowerReader = ChargingPowerReader()

    func collect(forceCableRefresh: Bool = false) -> ResourceSnapshot {
        var snapshot = ResourceSnapshot()
        snapshot.cpuPercent = sampleCPU()

        let memory = sampleMemory()
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.memoryPercent = memory.total > 0 ? Double(memory.used) / Double(memory.total) * 100 : 0

        let disk = sampleDisk()
        snapshot.diskUsed = disk.used
        snapshot.diskTotal = disk.total
        snapshot.diskPercent = disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0

        let network = sampleNetwork()
        snapshot.downloadBytesPerSecond = network.receivedPerSecond
        snapshot.uploadBytesPerSecond = network.sentPerSecond
        snapshot.networkInterface = network.interface

        if batterySampleCounter == 0 {
            cachedBattery = sampleBattery()
        }
        batterySampleCounter = (batterySampleCounter + 1) % 5
        snapshot.batteryText = cachedBattery.text
        snapshot.batteryPercent = cachedBattery.percent
        snapshot.powerSource = cachedBattery.source

        if let temperatures = smc.cpuTemperatures() {
            snapshot.cpuTemperature = temperatures.average
            snapshot.hottestCPUTemperature = temperatures.hottest
        }
        let fan = smc.fanReading()
        snapshot.fanSpeed = fan.speed
        snapshot.fanCount = fan.count
        snapshot.thermalState = thermalStateText()

        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        snapshot.processes = sampleTopProcesses()
        snapshot.chargingPower = chargingPowerReader.read()

        if forceCableRefresh || cableSampleCounter == 0 {
            let reading = cableCollector.collect()
            if reading.errorText == nil || cachedCableMonitor.ports.isEmpty {
                cachedCableMonitor = reading
            }
        }
        cableSampleCounter = (cableSampleCounter + 1) % 3
        snapshot.cableMonitor = cachedCableMonitor
        snapshot.updatedAt = Date()
        return snapshot
    }

    private func thermalStateText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "略高"
        case .serious: return "较高"
        case .critical: return "严重"
        @unknown default: return "未知"
        }
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let ticks = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks else { return 0 }

        let user = ticks.user >= previous.user ? ticks.user - previous.user : 0
        let system = ticks.system >= previous.system ? ticks.system - previous.system : 0
        let idle = ticks.idle >= previous.idle ? ticks.idle - previous.idle : 0
        let nice = ticks.nice >= previous.nice ? ticks.nice - previous.nice : 0
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return min(100, max(0, Double(user + system + nice) / Double(total) * 100))
    }

    private func sampleMemory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        let pageSize = UInt64(vm_kernel_page_size)
        let availablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        let available = min(total, availablePages * pageSize)
        return (total - available, total)
    }

    private func sampleDisk() -> (used: UInt64, total: UInt64) {
        let disk = StorageManager.diskUsage()
        return (disk.used, disk.total)
    }

    private func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacResourceMonitor" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let interface = value["PrimaryInterface"] as? String else {
            return nil
        }
        return interface
    }

    private func sampleNetwork() -> (receivedPerSecond: Double, sentPerSecond: Double, interface: String) {
        let wantedInterface = primaryInterface()
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return (0, 0, wantedInterface ?? "--")
        }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let item = current.pointee
            let name = String(cString: item.ifa_name)
            if name == wantedInterface,
               let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               let data = item.ifa_data {
                let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                received = UInt64(networkData.ifi_ibytes)
                sent = UInt64(networkData.ifi_obytes)
                break
            }
            pointer = item.ifa_next
        }

        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork else {
            return (0, 0, wantedInterface ?? "--")
        }
        let elapsed = max(0.2, now.timeIntervalSince(previous.date))
        let receivedDelta = received >= previous.received ? received - previous.received : 0
        let sentDelta = sent >= previous.sent ? sent - previous.sent : 0
        return (Double(receivedDelta) / elapsed, Double(sentDelta) / elapsed, wantedInterface ?? "--")
    }

    private func run(_ executable: String, _ arguments: [String]) -> String? {
        guard let result = CommandRunner.run(
            executable,
            arguments: arguments,
            timeout: 4
        ), !result.timedOut, result.terminationStatus == 0 else { return nil }
        return result.outputString
    }

    private func sampleBattery() -> (text: String, percent: Double?, source: String) {
        guard let output = run("/usr/bin/pmset", ["-g", "batt"]) else {
            return ("不可用", nil, "未知")
        }
        let lower = output.lowercased()
        let source: String
        if lower.contains("ac power") {
            source = "电源适配器"
        } else if lower.contains("battery power") {
            source = "电池供电"
        } else {
            source = "无电池"
        }

        guard let percentRange = output.range(of: #"\d+%"#, options: .regularExpression) else {
            return (source == "无电池" ? "无内置电池" : "不可用", nil, source)
        }
        let percentString = output[percentRange].dropLast()
        let percent = Double(percentString) ?? 0
        var state = ""
        if lower.contains("discharging") {
            state = " · 使用中"
        } else if lower.contains("charging") && !lower.contains("not charging") {
            state = " · 充电中"
        } else if lower.contains("charged") {
            state = " · 已充满"
        }
        return ("\(Int(percent))%\(state)", percent, source)
    }

    private func sampleTopProcesses() -> [ProcessRow] {
        guard let output = run("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]) else { return [] }
        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n").prefix(40) {
            let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = UInt64(fields[2]) else { continue }
            var name = String(fields[3])
            if name.contains("/") {
                name = URL(fileURLWithPath: name).lastPathComponent
            }
            rows.append(ProcessRow(id: pid, name: name, cpu: cpu, memoryBytes: rssKB * 1024))
            if rows.count == 6 { break }
        }
        return rows
    }
}

private final class MonitorModel: ObservableObject {
    private(set) var snapshot = ResourceSnapshot()
    private(set) var cpuHistory = Array(repeating: 0.0, count: 60)
    private(set) var memoryHistory = Array(repeating: 0.0, count: 60)
    @Published var isRefreshingCable = false
    @Published var lastCableRefreshAt: Date?

    private let collector = SystemCollector()
    private let queue = DispatchQueue(label: "local.mac-resource-monitor.collector", qos: .utility)
    private var timer: Timer?
    private var refreshInProgress = false
    private var forceCableRefreshPending = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh(forceCableRefresh: Bool = false) {
        if forceCableRefresh {
            forceCableRefreshPending = true
            isRefreshingCable = true
        }
        guard !refreshInProgress else { return }
        let shouldForceCableRefresh = forceCableRefreshPending
        forceCableRefreshPending = false
        refreshInProgress = true
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.collector.collect(forceCableRefresh: shouldForceCableRefresh)
            DispatchQueue.main.async {
                let nextCPUHistory = Array(self.cpuHistory.suffix(59)) + [next.cpuPercent]
                let nextMemoryHistory = Array(self.memoryHistory.suffix(59)) + [next.memoryPercent]
                self.objectWillChange.send()
                withTransaction(Transaction(animation: nil)) {
                    self.snapshot = next
                    self.cpuHistory = nextCPUHistory
                    self.memoryHistory = nextMemoryHistory
                    self.refreshInProgress = false
                    if shouldForceCableRefresh {
                        self.isRefreshingCable = false
                        self.lastCableRefreshAt = next.updatedAt
                    }
                }
                if self.forceCableRefreshPending {
                    self.refresh()
                }
            }
        }
    }

    func refreshCableMonitor() {
        refresh(forceCableRefresh: true)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let percent: Double?
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(InterfacePalette.iconSurface)
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 32, height: 32)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 7) {
                if let percent {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.14))
                            Capsule().fill(color.gradient)
                                .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                        }
                    }
                    .frame(height: 6)
                } else {
                    Spacer().frame(height: 6)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .glassCard()
    }
}

private struct ContentSectionLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            Text(subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 3)
    }
}

private struct HistoryChart: View {
    let title: String
    let value: Double
    let values: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { geometry in
                ZStack {
                    VStack {
                        ForEach(0..<5, id: \.self) { _ in
                            Divider().opacity(0.35)
                            Spacer()
                        }
                    }
                    chartPath(in: geometry.size, close: true)
                        .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    chartPath(in: geometry.size, close: false)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 132)
            .clipped()
            HStack {
                Text("2 分钟前")
                Spacer()
                Text("现在")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .transaction { transaction in
            transaction.animation = nil
        }
        .stableDashboardCard(cornerRadius: InterfaceMetrics.cardRadius)
    }

    private func chartPath(in size: CGSize, close: Bool) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, rawValue) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let clamped = min(100, max(0, rawValue))
            let y = size.height * (1 - CGFloat(clamped / 100))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if close {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }
}

private struct ProcessTable: View {
    let rows: [ProcessRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CPU 占用较高的进程")
                .font(.system(size: 14, weight: .semibold))
            HStack {
                Text("进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("PID").frame(width: 64, alignment: .trailing)
                Text("CPU").frame(width: 64, alignment: .trailing)
                Text("内存").frame(width: 78, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)

            if rows.isEmpty {
                Spacer()
                Text("正在读取进程…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(row.id)").frame(width: 64, alignment: .trailing)
                        Text(String(format: "%.1f%%", row.cpu)).frame(width: 64, alignment: .trailing)
                        Text(formatBytes(row.memoryBytes)).frame(width: 78, alignment: .trailing)
                    }
                    .font(.system(size: 12, design: .rounded))
                    .monospacedDigit()
                    if row.id != rows.last?.id { Divider().opacity(0.4) }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 225, alignment: .topLeading)
        .glassCard()
    }
}

private struct SystemDetails: View {
    let snapshot: ResourceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("系统状态").font(.system(size: 14, weight: .semibold))
            detail("网络接口", snapshot.networkInterface, "network")
            Divider().opacity(0.45)
            detail("供电方式", snapshot.powerSource, "bolt.fill")
            Divider().opacity(0.45)
            detail("电池状态", snapshot.batteryText, "battery.75percent")
            Divider().opacity(0.45)
            detail("系统热状态", snapshot.thermalState, "thermometer.medium")
            Divider().opacity(0.45)
            detail("运行时间", formatUptime(snapshot.uptime), "clock.arrow.circlepath")
            Divider().opacity(0.45)
            detail("设备", Host.current().localizedName ?? "Mac", "desktopcomputer")
        }
        .padding(18)
        .frame(width: 300, alignment: .topLeading)
        .frame(minHeight: 225, alignment: .topLeading)
        .glassCard()
    }

    private func detail(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
    }
}

private struct CableSection: View {
    let monitor: CableMonitorSnapshot
    let chargingPower: ChargingPowerSnapshot

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("USB-C 与线缆", systemImage: "cable.connector")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if let errorText = monitor.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    Text("检测到 \(monitor.ports.count) 个端口 · \(monitor.activePorts.count) 个已连接")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if monitor.ports.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.errorText ?? "没有发现可读取的 USB-C 端口")
                            .font(.system(size: 13, weight: .medium))
                        Text("该功能需要 Apple 芯片和 macOS 14 或更高版本")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .glassEffect(
                    .clear,
                    in: RoundedRectangle(cornerRadius: InterfaceMetrics.cardRadius, style: .continuous)
                )
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(monitor.ports) { port in
                        CablePortCard(
                            port: port,
                            liveInputWatts: liveInputWatts(for: port)
                        )
                    }
                }
            }

            Text("只读检测 · 线缆 E-Marker 仅在 macOS 实际读取到时显示 · 已关闭深度 USB 探测")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .glassCard()
    }

    private func liveInputWatts(for port: CablePortSnapshot) -> Double? {
        let chargingPorts = monitor.activePorts.filter { $0.negotiatedPower != nil }
        guard chargingPorts.count == 1,
              chargingPorts.first?.id == port.id else { return nil }
        return chargingPower.inputWatts
    }
}

private struct PortMonitorView: View {
    let monitor: CableMonitorSnapshot
    let chargingPower: ChargingPowerSnapshot

    var body: some View {
        CableSection(monitor: monitor, chargingPower: chargingPower)
    }
}

private struct CablePortCard: View {
    let port: CablePortSnapshot
    let liveInputWatts: Double?

    private var accent: Color {
        if port.warning != nil { return .orange }
        if port.connected { return .blue }
        return .secondary
    }

    private var symbol: String {
        if !port.connected { return "cable.connector.slash" }
        if port.activeTransports.contains("Thunderbolt/USB4") { return "bolt.horizontal.circle.fill" }
        if port.activeTransports.contains("DisplayPort") { return "display" }
        return "cable.connector"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(InterfacePalette.iconSurface)
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(port.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(port.stateTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accent)
                }
                Spacer()
                Circle()
                    .fill(port.connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }

            Text(port.stateDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if port.connected {
                VStack(spacing: 8) {
                    if let value = port.negotiatedPower {
                        cableDetail("协商上限", value, "bolt.fill")
                    }
                    if let watts = liveInputWatts {
                        cableDetail("实时输入", String(format: "%.1f W", watts), "gauge.with.dots.needle.50percent")
                    }
                    if let value = port.dataLinkSummary {
                        cableDetail("数据链路", value, "arrow.left.arrow.right")
                    }
                    if let value = port.cableSpeed {
                        cableDetail("线缆速率", value, "speedometer")
                    }
                    if let value = port.cablePower {
                        cableDetail("线缆额定", value, "powerplug.fill")
                    }
                    if let value = port.cableVendor {
                        cableDetail("E-Marker", value, "cpu")
                    }
                    if let value = port.trustText {
                        cableDetail("能力判断", value, "checkmark.shield")
                    }
                    if let value = port.warning {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(value)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                    if !port.hasCableIdentity {
                        Text("macOS 尚未读取到线缆 E-Marker；普通 3A 或仅充电线缆可能不提供该信息。")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(port.supportedTransports.isEmpty
                     ? (port.type.localizedCaseInsensitiveContains("MagSafe") ? "磁吸充电端口" : "当前无传输能力数据")
                     : "支持：\(port.supportedTransports.joined(separator: " · "))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: port.connected ? 178 : 132, alignment: .topLeading)
        .glassCard()
    }

    private func cableDetail(_ label: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case monitor = "系统监控"
    case traffic = "进程流量"
    case ports = "接口监测"
    case cleanup = "存储清理"
    case uninstall = "应用卸载"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .monitor: return "gauge.with.dots.needle.50percent"
        case .traffic: return "point.3.connected.trianglepath.dotted"
        case .ports: return "cable.connector"
        case .cleanup: return "internaldrive"
        case .uninstall: return "square.grid.2x2"
        }
    }

    var tint: Color {
        InterfacePalette.accent
    }

    var subtitle: String {
        switch self {
        case .monitor: return "性能与硬件状态"
        case .traffic: return "实时进程上下行"
        case .ports: return "USB-C、雷雳与供电"
        case .cleanup: return "空间分析与安全清理"
        case .uninstall: return "应用占用与完整移除"
        }
    }

    var eyebrow: String {
        switch self {
        case .monitor: return "MAC HEALTH"
        case .traffic: return "PROCESS TRAFFIC"
        case .ports: return "CONNECTED DEVICES"
        case .cleanup: return "STORAGE CARE"
        case .uninstall: return "APPLICATIONS"
        }
    }
}

enum InterfaceMetrics {
    static let panelRadius: CGFloat = 28
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 14
}

enum InterfacePalette {
    /// A restrained accent shared by navigation and primary actions.
    static let accent = Color(red: 0.33, green: 0.40, blue: 0.47)
    /// Neutral inset used behind glyphs so cards do not read as color swatches.
    static let iconSurface = Color.primary.opacity(0.060)
    static let cardStroke = Color.primary.opacity(0.075)

    static func stableSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.070, green: 0.074, blue: 0.080)
            : Color(nsColor: .controlBackgroundColor)
    }

    static func stableDashboardSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.235, green: 0.240, blue: 0.250)
            : Color(red: 0.975, green: 0.975, blue: 0.980)
    }
}

struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .glassEffect(.clear, in: shape)
            .overlay(shape.stroke(InterfacePalette.cardStroke, lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.035), radius: 14, y: 6)
    }
}

struct StableListCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                InterfacePalette.stableSurface(for: colorScheme),
                in: shape
            )
            .overlay(shape.stroke(InterfacePalette.cardStroke, lineWidth: 0.75))
            .clipShape(shape)
    }
}

struct StableDashboardCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(InterfacePalette.stableDashboardSurface(for: colorScheme), in: shape)
            .overlay(shape.stroke(InterfacePalette.cardStroke, lineWidth: 0.75))
            .clipShape(shape)
            .shadow(color: Color.black.opacity(0.035), radius: 14, y: 6)
    }
}

struct StableMenuCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                Color.white.opacity(colorScheme == .dark ? 0.055 : 0.30),
                in: shape
            )
            .overlay(shape.stroke(InterfacePalette.cardStroke, lineWidth: 0.75))
            .clipShape(shape)
    }
}

@MainActor
private final class TransparentWindowBridgeView: NSView {
    private weak var configuredWindow: NSWindow?
    private weak var configuredContentView: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            configuredWindow = nil
            configuredContentView = nil
        } else {
            configureWindowIfNeeded()
        }
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        let contentView = window.contentView
        guard configuredWindow !== window || configuredContentView !== contentView else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        configuredWindow = window
        configuredContentView = contentView
    }
}

private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> TransparentWindowBridgeView {
        TransparentWindowBridgeView(frame: .zero)
    }

    func updateNSView(_ nsView: TransparentWindowBridgeView, context: Context) {
        nsView.configureWindowIfNeeded()
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = InterfaceMetrics.cardRadius) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    func stableListCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(StableListCardModifier(cornerRadius: cornerRadius))
    }

    func stableDashboardCard(cornerRadius: CGFloat = InterfaceMetrics.cardRadius) -> some View {
        modifier(StableDashboardCardModifier(cornerRadius: cornerRadius))
    }

    func stableMenuCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(StableMenuCardModifier(cornerRadius: cornerRadius))
    }
}

private struct SidebarNavigationItem: View {
    let section: DashboardSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    @ViewBuilder
    var body: some View {
        if isSelected {
            navigationButton
                .glassEffect(
                    .clear.interactive(),
                    in: RoundedRectangle(cornerRadius: InterfaceMetrics.controlRadius, style: .continuous)
                )
                .onHover { isHovering = $0 }
        } else {
            navigationButton
                .onHover { isHovering = $0 }
        }
    }

    private var navigationButton: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(InterfacePalette.iconSurface)
                    Image(systemName: section.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? section.tint : Color.secondary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    Text(section.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Capsule()
                        .fill(section.tint.gradient)
                        .frame(width: 4, height: 25)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovering && !isSelected ? 0.045 : 0), in: RoundedRectangle(cornerRadius: InterfaceMetrics.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var processNetworkModel: ProcessNetworkMonitor
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var storageModel = StorageManager()
    @State private var selectedSection: DashboardSection = .monitor
    @State private var storagePage: StoragePage = .overview

    var body: some View {
        ZStack {
            ambientBackground
            HStack(spacing: 14) {
                sidebar
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        contentHeader
                        sectionContent
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
                .scrollClipDisabled(false)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .id("\(selectedSection.id)-\(storagePage.rawValue)")
            }
            .padding(12)
        }
        .frame(minWidth: 1040, idealWidth: 1200, minHeight: 720, idealHeight: 860)
        .background(WindowTransparencyConfigurator())
    }

    @ViewBuilder
    private var sectionContent: some View {
        if selectedSection == .monitor {
            VStack(spacing: 16) {
                    ContentSectionLabel(title: "实时资源", subtitle: "每 2 秒自动更新")
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ], spacing: 12) {
                        MetricCard(
                            title: "处理器", value: String(format: "%.1f%%", model.snapshot.cpuPercent),
                            subtitle: "所有核心的总占用", percent: model.snapshot.cpuPercent,
                            color: .cyan, symbol: "cpu"
                        )
                        MetricCard(
                            title: "内存", value: formatBytes(model.snapshot.memoryUsed),
                            subtitle: "共 \(formatBytes(model.snapshot.memoryTotal))", percent: model.snapshot.memoryPercent,
                            color: .purple, symbol: "memorychip"
                        )
                        MetricCard(
                            title: "磁盘", value: formatStorageBytes(model.snapshot.diskUsed),
                            subtitle: "共 \(formatStorageBytes(model.snapshot.diskTotal))", percent: model.snapshot.diskPercent,
                            color: .orange, symbol: "internaldrive"
                        )
                        MetricCard(
                            title: "实时网络", value: "↓ \(formatRate(model.snapshot.downloadBytesPerSecond))",
                            subtitle: "↑ \(formatRate(model.snapshot.uploadBytesPerSecond)) · \(model.snapshot.networkInterface)", percent: nil,
                            color: .green, symbol: "network"
                        )
                        MetricCard(
                            title: "CPU 温度", value: formatTemperature(model.snapshot.cpuTemperature),
                            subtitle: temperatureSubtitle(model.snapshot), percent: nil,
                            color: .red, symbol: "thermometer.medium"
                        )
                        MetricCard(
                            title: "风扇转速", value: formatFanSpeed(model.snapshot.fanSpeed),
                            subtitle: fanSubtitle(model.snapshot), percent: nil,
                            color: .indigo, symbol: "fan.fill"
                        )
                        MetricCard(
                            title: "实时充电功率", value: formatBatteryChargePower(model.snapshot.chargingPower),
                            subtitle: chargingPowerSubtitle(model.snapshot.chargingPower), percent: nil,
                            color: .mint, symbol: "battery.100percent.bolt"
                        )
                        MetricCard(
                            title: "电池与供电", value: model.snapshot.batteryText,
                            subtitle: model.snapshot.powerSource, percent: model.snapshot.batteryPercent,
                            color: .yellow, symbol: "bolt.circle.fill"
                        )
                    }
                    ContentSectionLabel(title: "性能趋势", subtitle: "最近约 2 分钟")
                    HStack(spacing: 12) {
                        HistoryChart(title: "CPU 历史", value: model.snapshot.cpuPercent, values: model.cpuHistory, color: .cyan)
                        HistoryChart(title: "内存历史", value: model.snapshot.memoryPercent, values: model.memoryHistory, color: .purple)
                    }
                    ContentSectionLabel(title: "活动与详情", subtitle: "本机只读数据")
                    HStack(alignment: .top, spacing: 12) {
                        ProcessTable(rows: model.snapshot.processes)
                        SystemDetails(snapshot: model.snapshot)
                    }
            }
        } else if selectedSection == .traffic {
            ProcessTrafficView(model: processNetworkModel)
        } else if selectedSection == .ports {
            PortMonitorView(
                monitor: model.snapshot.cableMonitor,
                chargingPower: model.snapshot.chargingPower
            )
        } else if selectedSection == .cleanup {
            StorageCleanupView(model: storageModel, selectedPage: $storagePage)
        } else {
            AppUninstallerView(model: storageModel)
        }
    }

    private var ambientBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            if colorScheme == .dark {
                Color.black.opacity(0.66)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.025),
                        Color.clear,
                        Color.black.opacity(0.045)
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            } else {
                Color.white.opacity(0.30)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.clear,
                        Color.black.opacity(0.025)
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            }
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac 资源监控")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("PERSONAL MAC CARE")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                }
            }

            sidebarGroupLabel("概览")
                .padding(.top, 32)

            GlassEffectContainer(spacing: 7) {
                VStack(spacing: 5) {
                    sidebarItem(.monitor)
                    sidebarItem(.traffic)
                }
            }

            sidebarGroupLabel("管理工具")
                .padding(.top, 20)

            GlassEffectContainer(spacing: 7) {
                VStack(spacing: 5) {
                    sidebarItem(.ports)
                    sidebarItem(.cleanup)
                    sidebarItem(.uninstall)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mac 状态在线")
                            .font(.system(size: 11, weight: .semibold))
                        Text("菜单栏持续监控")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.0f%%", model.snapshot.cpuPercent))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("CPU")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTemperature(model.snapshot.cpuTemperature))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
            }
            .padding(15)
            .glassCard()
        }
        .padding(.horizontal, 17)
        .padding(.top, 46)
        .padding(.bottom, 17)
        .frame(width: 232)
        .glassEffect(
            .clear,
            in: RoundedRectangle(cornerRadius: InterfaceMetrics.panelRadius, style: .continuous)
        )
    }

    private func sidebarGroupLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.9)
            .foregroundStyle(Color.primary.opacity(0.72))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    private func sidebarItem(_ section: DashboardSection) -> some View {
        SidebarNavigationItem(section: section, isSelected: selectedSection == section) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if section == .cleanup && selectedSection != .cleanup {
                    storagePage = .overview
                }
                selectedSection = section
            }
        }
    }

    private var contentHeader: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 24) {
                if selectedSection != .uninstall {
                    heroIndicator
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(selectedSection.eyebrow)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(selectedSection.tint)
                    Text(heroTitle)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Label(heroStatusDetail, systemImage: "checkmark.shield.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.035), in: Capsule())
                        Text(heroFootnote)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 20)

                VStack(alignment: .trailing, spacing: 12) {
                    Text(heroValue)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(heroValueLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button(action: performHeroAction) {
                            Label(heroActionTitle, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(selectedSection.tint)
                        .disabled(isHeroActionDisabled)
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .leading)
        .glassCard(cornerRadius: InterfaceMetrics.panelRadius)
    }

    private var heroIndicator: some View {
        ZStack {
            Circle()
                .fill(selectedSection.tint.opacity(0.10))
            Circle()
                .stroke(selectedSection.tint.opacity(0.10), lineWidth: 8)
                .padding(8)
            Circle()
                .trim(from: 0, to: max(0.06, heroProgress))
                .stroke(
                    selectedSection.tint.gradient,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(8)

            if selectedSection == .monitor {
                VStack(spacing: 1) {
                    Text("\(Int((heroProgress * 100).rounded()))%")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("系统负载")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(selectedSection.tint)
            } else {
                Image(systemName: selectedSection.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(selectedSection.tint)
            }
        }
        .frame(width: 100, height: 100)
        .shadow(color: selectedSection.tint.opacity(0.28), radius: 22)
    }

    private var heroTitle: String {
        switch selectedSection {
        case .monitor:
            if model.snapshot.thermalState != "正常" || model.snapshot.cpuPercent >= 85 || model.snapshot.memoryPercent >= 90 {
                return "Mac 需要关注"
            }
            return "Mac 状态良好"
        case .traffic: return "每个进程的流量都看得见"
        case .ports: return "连接状态一目了然"
        case .cleanup: return "为重要内容留出空间"
        case .uninstall: return "让应用保持井然有序"
        }
    }

    private var heroStatusDetail: String {
        switch selectedSection {
        case .monitor: return "后台实时监控"
        case .traffic: return "系统原生只读采样"
        case .ports: return "仅检测，不修改端口"
        case .cleanup: return "默认只读，清理前确认"
        case .uninstall: return "应用移入废纸篓"
        }
    }

    private var heroFootnote: String {
        switch selectedSection {
        case .monitor: return "最近更新 \(model.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
        case .traffic:
            if let date = processNetworkModel.lastUpdatedAt {
                return "最近采样 \(date.formatted(date: .omitted, time: .standard))"
            }
            return processNetworkModel.errorText ?? "正在建立流量基线"
        case .ports:
            if let date = model.lastCableRefreshAt {
                return "最近检测 \(date.formatted(date: .omitted, time: .standard))"
            }
            return "不会执行 USB 控制传输"
        case .cleanup: return "个人文件不会自动删除"
        case .uninstall: return "仅匹配精确 Bundle ID"
        }
    }

    private var heroValue: String {
        switch selectedSection {
        case .monitor: return formatTemperature(model.snapshot.cpuTemperature)
        case .traffic: return "↓ \(formatRate(processNetworkModel.downloadBytesPerSecond))"
        case .ports: return "\(model.snapshot.cableMonitor.activePorts.count) 个"
        case .cleanup: return formatStorageBytes(storageModel.diskAvailable)
        case .uninstall: return "\(storageModel.installedApplications.count) 个"
        }
    }

    private var heroValueLabel: String {
        switch selectedSection {
        case .monitor: return "当前 CPU 温度"
        case .traffic: return "↑ \(formatRate(processNetworkModel.uploadBytesPerSecond))"
        case .ports: return "已连接端口"
        case .cleanup: return "磁盘可用空间"
        case .uninstall: return "已识别第三方应用"
        }
    }

    private var heroProgress: Double {
        switch selectedSection {
        case .monitor:
            return min(1, max(model.snapshot.cpuPercent, model.snapshot.memoryPercent) / 100)
        case .traffic:
            let total = processNetworkModel.downloadBytesPerSecond + processNetworkModel.uploadBytesPerSecond
            return total > 0 ? min(1, log10(total + 1) / 8) : 0.06
        case .ports:
            let total = model.snapshot.cableMonitor.ports.count
            return total > 0 ? Double(model.snapshot.cableMonitor.activePorts.count) / Double(total) : 0.06
        case .cleanup:
            return storageModel.diskTotal > 0 ? min(1, Double(storageModel.diskUsed) / Double(storageModel.diskTotal)) : 0.06
        case .uninstall:
            return 0
        }
    }

    private var heroActionTitle: String {
        switch selectedSection {
        case .monitor: return "刷新"
        case .traffic: return "清零累计"
        case .ports: return model.isRefreshingCable ? "检测中" : "重新检测"
        case .cleanup:
            return (storageModel.isScanningStorageUsage || storageModel.isScanningCleanup) ? "扫描中" : "扫描空间"
        case .uninstall: return storageModel.isScanningApplications ? "扫描中" : "扫描应用"
        }
    }

    private var isHeroActionDisabled: Bool {
        switch selectedSection {
        case .monitor: return false
        case .traffic: return false
        case .ports: return model.isRefreshingCable
        case .cleanup: return storageModel.isScanningStorageUsage || storageModel.isScanningCleanup || storageModel.isCleaning
        case .uninstall: return storageModel.isScanningApplications || storageModel.uninstallingAppID != nil
        }
    }

    private func performHeroAction() {
        switch selectedSection {
        case .monitor:
            model.refresh()
        case .traffic:
            processNetworkModel.resetSessionTotals()
        case .ports:
            model.refreshCableMonitor()
        case .cleanup:
            storageModel.scanStorageUsage()
            storageModel.scanCleanup()
        case .uninstall:
            storageModel.scanApplications()
        }
    }

    private var headerSubtitle: String {
        switch selectedSection {
        case .monitor: return "实时观察处理器、内存、温度、风扇和网络状态 · 每 2 秒刷新"
        case .traffic: return "按进程查看实时下载、上传与本次监控累计流量 · 不接管网络连接"
        case .ports: return "检查 USB-C、Thunderbolt、DisplayPort 与充电协商状态"
        case .cleanup: return "找出空间大户，安全清理可重新生成的数据"
        case .uninstall: return "按占用排序管理第三方应用及精确匹配的用户残留"
        }
    }
}

private struct MenuBarPresentationState {
    var resource = ResourceSnapshot()
    var traffic = ProcessTrafficDisplayState()
}

private struct MenuBarPanel: View {
    let model: MonitorModel
    let processNetworkModel: ProcessNetworkMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var presentation = MenuBarPresentationState()

    var body: some View {
        ZStack {
            menuBackground

            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac 状态")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text("实时监控中")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                HStack(spacing: 10) {
                    primaryMenuMetric(
                        title: "CPU 温度",
                        value: formatTemperature(snapshot.cpuTemperature),
                        subtitle: snapshot.hottestCPUTemperature.map { String(format: "最高 %.1f°C", $0) } ?? "传感器不可用",
                        symbol: "thermometer.medium",
                        color: .red
                    )
                    primaryMenuMetric(
                        title: "实时网络",
                        value: "↓ \(formatRate(snapshot.downloadBytesPerSecond))",
                        subtitle: "↑ \(formatRate(snapshot.uploadBytesPerSecond)) · \(snapshot.networkInterface)",
                        symbol: "arrow.down.arrow.up",
                        color: .green
                    )
                }

                HStack(spacing: 8) {
                    compactMenuMetric("CPU", String(format: "%.0f%%", snapshot.cpuPercent))
                    compactMenuMetric("内存", String(format: "%.0f%%", snapshot.memoryPercent))
                    compactMenuMetric("风扇", compactFanSpeed(snapshot.fanSpeed))
                }

                processTrafficRanking

                HStack(spacing: 10) {
                    Image(systemName: cableStatusSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(cableStatusColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cableStatusTitle)
                            .font(.system(size: 11, weight: .semibold))
                        Text(cableStatusSubtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(formatBatteryChargePower(snapshot.chargingPower))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.mint)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .stableMenuCard(cornerRadius: 14)

                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("打开监控面板", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(InterfacePalette.accent)

                HStack {
                    Text("只读监控 · 每 2 秒更新")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 2)
            }
            .padding(14)
        }
        .frame(width: 350)
        .background(WindowTransparencyConfigurator())
        .onAppear {
            presentation = MenuBarPresentationState(
                resource: model.snapshot,
                traffic: processNetworkModel.displayState
            )
            processNetworkModel.setActive(true, for: .menuBar)
        }
        .onDisappear { processNetworkModel.setActive(false, for: .menuBar) }
        .onReceive(processNetworkModel.$displayState) { traffic in
            presentation = MenuBarPresentationState(
                resource: model.snapshot,
                traffic: traffic
            )
        }
    }

    private var snapshot: ResourceSnapshot { presentation.resource }
    private var menuTraffic: ProcessTrafficDisplayState { presentation.traffic }

    private var menuBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.14 : 0.22),
                    InterfacePalette.accent.opacity(colorScheme == .dark ? 0.055 : 0.035),
                    Color.white.opacity(colorScheme == .dark ? 0.045 : 0.10)
                ],
                startPoint: .topTrailing,
                endPoint: .bottomLeading
            )
        }
        .ignoresSafeArea()
    }

    private var topTrafficRows: [ProcessTrafficRow] {
        Array(menuTraffic.rows
            .sorted { $0.currentBytesPerSecond > $1.currentBytesPerSecond }
            .prefix(5))
    }

    private var processTrafficRanking: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                Text("进程流量 Top 5")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("↓\(formatMenuBarRate(menuTraffic.downloadBytesPerSecond))  ↑\(formatMenuBarRate(menuTraffic.uploadBytesPerSecond))")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if topTrafficRows.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(menuTraffic.errorText ?? "正在建立进程流量基线")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(height: 24)
            } else {
                ForEach(Array(topTrafficRows.enumerated()), id: \.element.id) { index, row in
                    menuTrafficRow(row, rank: index + 1)
                }
            }
        }
        .padding(12)
        .stableMenuCard(cornerRadius: 16)
    }

    private func menuTrafficRow(_ row: ProcessTrafficRow, rank: Int) -> some View {
        HStack(spacing: 7) {
            Text("\(rank)")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 10, alignment: .trailing)

            menuTrafficIcon(pid: row.pid, name: row.name)

            Text(row.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("↓\(formatMenuBarRate(row.downloadBytesPerSecond))")
                .foregroundStyle(.green)
                .frame(width: 46, alignment: .trailing)
            Text("↑\(formatMenuBarRate(row.uploadBytesPerSecond))")
                .foregroundStyle(.blue)
                .frame(width: 46, alignment: .trailing)
        }
        .font(.system(size: 8, weight: .medium, design: .rounded))
        .monospacedDigit()
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func menuTrafficIcon(pid: Int32, name: String) -> some View {
        if let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(InterfacePalette.iconSurface)
                .overlay {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 18, height: 18)
        }
    }

    private func primaryMenuMetric(title: String, value: String, subtitle: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
        .stableMenuCard(cornerRadius: 16)
    }

    private func compactMenuMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stableMenuCard(cornerRadius: 13)
    }

    private var cableStatusTitle: String {
        let active = snapshot.cableMonitor.activePorts.count
        let total = snapshot.cableMonitor.ports.count
        return "接口状态 · \(active)/\(total) 已连接"
    }

    private var cableStatusSubtitle: String {
        if let error = snapshot.cableMonitor.errorText,
           snapshot.cableMonitor.ports.isEmpty {
            return error
        }
        guard let port = snapshot.cableMonitor.activePorts.first else {
            return "没有连接的 USB-C 或雷雳设备"
        }
        return "\(port.displayName) · \(menuCableSubtitle(port))"
    }

    private var cableStatusSymbol: String {
        snapshot.cableMonitor.activePorts.isEmpty ? "cable.connector.slash" : "cable.connector"
    }

    private var cableStatusColor: Color {
        snapshot.cableMonitor.errorText == nil ? .blue : .orange
    }
}

private func menuCableSubtitle(_ port: CablePortSnapshot) -> String {
    if let warning = port.warning { return warning }
    if let power = port.negotiatedPower { return "\(port.stateTitle) · \(power)" }
    if let link = port.dataLinkSummary { return link }
    return port.stateTitle
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  isDashboardWindow(window) else { return }
            DispatchQueue.main.async {
                let dashboardStillVisible = NSApp.windows.contains {
                    isDashboardWindow($0) && $0.isVisible
                }
                if !dashboardStillVisible {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }
}

private func isDashboardWindow(_ window: NSWindow) -> Bool {
    if window.identifier?.rawValue == "dashboard" { return true }
    return window.level == .normal && window.styleMask.contains(.closable) && window.canBecomeMain
}

private func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}

private func formatStorageBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}

private func formatRate(_ bytesPerSecond: Double) -> String {
    let value = UInt64(max(0, bytesPerSecond))
    return "\(formatBytes(value))/s"
}

private func formatTemperature(_ value: Double?) -> String {
    guard let value else { return "不可用" }
    return String(format: "%.1f°C", value)
}

private func temperatureSubtitle(_ snapshot: ResourceSnapshot) -> String {
    guard let hottest = snapshot.hottestCPUTemperature else { return "未能读取 SMC 温度传感器" }
    return String(format: "最高 %.1f°C · M5 传感器平均", hottest)
}

private func formatFanSpeed(_ value: Double?) -> String {
    guard let value else { return "不可用" }
    return "\(Int(value.rounded())) RPM"
}

private func fanSubtitle(_ snapshot: ResourceSnapshot) -> String {
    guard snapshot.fanCount > 0 else { return "未检测到内置风扇" }
    let countText = snapshot.fanCount == 1 ? "1 个内置风扇" : "\(snapshot.fanCount) 个内置风扇"
    if snapshot.fanSpeed == 0 { return "\(countText) · 当前停转" }
    return "\(countText) · 自动控制"
}

private func formatBatteryChargePower(_ power: ChargingPowerSnapshot) -> String {
    guard power.externalConnected else { return "未接电源" }
    guard power.isCharging else { return "未充电" }
    guard let watts = power.batteryChargeWatts else { return "检测中" }
    return String(format: "%.1f W", watts)
}

private func chargingPowerSubtitle(_ power: ChargingPowerSnapshot) -> String {
    guard power.externalConnected else { return "连接充电器后显示实时功率" }
    var parts: [String] = []
    if let input = power.inputWatts {
        parts.append(String(format: "适配器输入 %.1f W", input))
    }
    if let load = power.systemLoadWatts {
        parts.append(String(format: "系统使用 %.1f W", load))
    }
    if !power.isCharging { parts.append("电池当前未充电") }
    return parts.isEmpty ? "正在读取电源传感器" : parts.joined(separator: " · ")
}

private func formatUptime(_ interval: TimeInterval) -> String {
    let totalMinutes = Int(interval) / 60
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days)天 \(hours)小时" }
    if hours > 0 { return "\(hours)小时 \(minutes)分" }
    return "\(minutes)分钟"
}

@main
private struct MacResourceMonitorApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = MonitorModel()
    @State private var processNetworkModel = ProcessNetworkMonitor()

    var body: some Scene {
        Window("Mac 资源监控", id: "dashboard") {
            DashboardView(model: model, processNetworkModel: processNetworkModel)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarPanel(model: model, processNetworkModel: processNetworkModel)
        } label: {
            MenuBarStatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        Text(menuBarSummary(model.snapshot))
            .monospacedDigit()
            .accessibilityLabel("Mac 资源监控 \(menuBarSummary(model.snapshot))")
    }
}

private func menuBarSummary(_ snapshot: ResourceSnapshot) -> String {
    let temperature = snapshot.cpuTemperature.map { "\(Int($0.rounded()))°" } ?? "--°"
    return "\(temperature)  ↓\(formatMenuBarRate(snapshot.downloadBytesPerSecond)) ↑\(formatMenuBarRate(snapshot.uploadBytesPerSecond))"
}

private func formatMenuBarRate(_ bytesPerSecond: Double) -> String {
    let value = max(0, bytesPerSecond)
    if value >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
    if value >= 10_000_000 { return String(format: "%.0fM", value / 1_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 10_000 { return String(format: "%.0fK", value / 1_000) }
    if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
    return "\(Int(value.rounded()))B"
}

private func compactFanSpeed(_ value: Double?) -> String {
    guard let value else { return "--" }
    return "\(Int(value.rounded())) RPM"
}
