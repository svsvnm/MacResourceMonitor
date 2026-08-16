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

    func collect() -> ResourceSnapshot {
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

        if cableSampleCounter == 0 {
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
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let totalNumber = attributes[.systemSize] as? NSNumber,
              let freeNumber = attributes[.systemFreeSize] as? NSNumber else {
            return (0, 0)
        }
        let total = totalNumber.uint64Value
        let free = freeNumber.uint64Value
        return (total >= free ? total - free : 0, total)
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
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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
    @Published var snapshot = ResourceSnapshot()
    @Published var cpuHistory = Array(repeating: 0.0, count: 60)
    @Published var memoryHistory = Array(repeating: 0.0, count: 60)
    @Published var isPaused = false

    private let collector = SystemCollector()
    private let queue = DispatchQueue(label: "local.mac-resource-monitor.collector", qos: .utility)
    private var timer: Timer?
    private var refreshInProgress = false

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func togglePause() {
        isPaused.toggle()
        if !isPaused { refresh() }
    }

    func refresh() {
        guard !isPaused, !refreshInProgress else { return }
        refreshInProgress = true
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.collector.collect()
            DispatchQueue.main.async {
                self.snapshot = next
                self.cpuHistory.removeFirst()
                self.cpuHistory.append(next.cpuPercent)
                self.memoryHistory.removeFirst()
                self.memoryHistory.append(next.memoryPercent)
                self.refreshInProgress = false
            }
        }
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
                        .fill(color.opacity(0.15))
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }
                .frame(width: 32, height: 32)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let percent {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(color)
                }
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
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .glassCard(cornerRadius: 20)
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
            .frame(minHeight: 132)
            HStack {
                Text("2 分钟前")
                Spacer()
                Text("现在")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
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
        .glassCard(cornerRadius: 20)
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
        .glassCard(cornerRadius: 20)
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
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .glassCard(cornerRadius: 22)
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
                        .fill(accent.opacity(port.connected ? 0.16 : 0.08))
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
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.18)))
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
    case ports = "端口监测"
    case cleanup = "存储清理"
    case uninstall = "应用卸载"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .monitor: return "gauge.with.dots.needle.50percent"
        case .ports: return "cable.connector"
        case .cleanup: return "internaldrive"
        case .uninstall: return "square.grid.2x2"
        }
    }

    var tint: Color {
        switch self {
        case .monitor: return .cyan
        case .ports: return .blue
        case .cleanup: return .orange
        case .uninstall: return .purple
        }
    }

    var subtitle: String {
        switch self {
        case .monitor: return "性能与硬件状态"
        case .ports: return "USB-C、雷雳与供电"
        case .cleanup: return "空间分析与安全清理"
        case .uninstall: return "应用占用与完整移除"
        }
    }
}

struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}

private struct SidebarNavigationItem: View {
    let section: DashboardSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(section.tint.opacity(isSelected ? 0.22 : 0.10))
                    Image(systemName: section.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? section.tint : Color.secondary)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(section.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    Text(section.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Circle()
                        .fill(section.tint)
                        .frame(width: 6, height: 6)
                        .shadow(color: section.tint.opacity(0.7), radius: 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(Color.white.opacity(isHovering && !isSelected ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .glassEffect(
                isSelected ? .regular.tint(section.tint.opacity(0.22)).interactive() : .clear.interactive(),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var storageModel = StorageManager()
    @State private var selectedSection: DashboardSection = .monitor
    @State private var storagePage: StoragePage = .overview

    var body: some View {
        ZStack {
            ambientBackground
            HStack(spacing: 0) {
                sidebar
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        contentHeader
                        GlassEffectContainer(spacing: 14) {
                            sectionContent
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 32)
                }
                .id("\(selectedSection.id)-\(storagePage.rawValue)")
            }
        }
        .frame(minWidth: 1040, idealWidth: 1200, minHeight: 720, idealHeight: 860)
    }

    @ViewBuilder
    private var sectionContent: some View {
        if selectedSection == .monitor {
            VStack(spacing: 16) {
                    LazyVGrid(columns: [
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
                            title: "磁盘", value: formatBytes(model.snapshot.diskUsed),
                            subtitle: "共 \(formatBytes(model.snapshot.diskTotal))", percent: model.snapshot.diskPercent,
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
                    }
                    HStack(spacing: 12) {
                        HistoryChart(title: "CPU 历史", value: model.snapshot.cpuPercent, values: model.cpuHistory, color: .cyan)
                        HistoryChart(title: "内存历史", value: model.snapshot.memoryPercent, values: model.memoryHistory, color: .purple)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        ProcessTable(rows: model.snapshot.processes)
                        SystemDetails(snapshot: model.snapshot)
                    }
            }
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
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Circle()
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: geometry.size.width * 0.55)
                    .blur(radius: 110)
                    .offset(x: geometry.size.width * 0.30, y: -geometry.size.height * 0.32)
                Circle()
                    .fill(Color.purple.opacity(0.10))
                    .frame(width: geometry.size.width * 0.48)
                    .blur(radius: 120)
                    .offset(x: geometry.size.width * 0.36, y: geometry.size.height * 0.40)
                Circle()
                    .fill(Color.blue.opacity(0.08))
                    .frame(width: geometry.size.width * 0.38)
                    .blur(radius: 100)
                    .offset(x: -geometry.size.width * 0.25, y: geometry.size.height * 0.14)
            }
            .ignoresSafeArea()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                .shadow(color: Color.blue.opacity(0.28), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac 资源监控")
                        .font(.system(size: 15, weight: .bold))
                    Text("本机性能管家")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("功能")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.top, 30)
                .padding(.bottom, 8)
                .padding(.horizontal, 8)

            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 5) {
                    ForEach(DashboardSection.allCases) { section in
                        SidebarNavigationItem(section: section, isSelected: selectedSection == section) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if section == .cleanup && selectedSection != .cleanup {
                                    storagePage = .overview
                                }
                                selectedSection = section
                            }
                        }
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(model.isPaused ? Color.orange : Color.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: (model.isPaused ? Color.orange : Color.green).opacity(0.7), radius: 4)
                    Text(model.isPaused ? "监控已暂停" : "后台监控运行中")
                        .font(.system(size: 11, weight: .medium))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.0f%%", model.snapshot.cpuPercent))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("CPU")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatTemperature(model.snapshot.cpuTemperature))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                Button {
                    dismissWindow(id: "dashboard")
                } label: {
                    Label("收起到菜单栏", systemImage: "menubar.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(13)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.top, 46)
        .padding(.bottom, 18)
        .frame(width: 226)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
        }
    }

    private var contentHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selectedSection.rawValue)
                    .font(.system(size: 28, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedSection == .monitor {
                HStack(spacing: 9) {
                    HStack(spacing: 6) {
                        Circle().fill(model.isPaused ? Color.orange : Color.green).frame(width: 7, height: 7)
                        Text(model.isPaused ? "已暂停" : "实时")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: Capsule())

                    Button(action: model.togglePause) {
                        Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 17, height: 17)
                    }
                    .buttonStyle(.glass)
                    .help(model.isPaused ? "继续监控" : "暂停监控")

                    Button(action: model.refresh) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 17, height: 17)
                    }
                    .buttonStyle(.glass)
                    .help("立即刷新")
                }
            } else {
                Label("只读本机数据", systemImage: "lock.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .glassEffect(.clear, in: Capsule())
            }
        }
        .padding(.horizontal, 2)
    }

    private var headerSubtitle: String {
        switch selectedSection {
        case .monitor: return "实时观察处理器、内存、温度、风扇和网络状态 · 每 2 秒刷新"
        case .ports: return "检查 USB-C、Thunderbolt、DisplayPort 与充电协商状态"
        case .cleanup: return "找出空间大户，安全清理可重新生成的数据"
        case .uninstall: return "按占用排序管理第三方应用及精确匹配的用户残留"
        }
    }
}

private struct MenuBarPanel: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac 资源监控")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(model.isPaused ? Color.orange : Color.green).frame(width: 6, height: 6)
                        Text(model.isPaused ? "已暂停" : "每 2 秒更新")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)

            Divider()

            VStack(spacing: 0) {
                menuMetric("CPU", String(format: "%.1f%%", model.snapshot.cpuPercent), "cpu", .cyan)
                Divider().padding(.leading, 38)
                menuMetric("内存", String(format: "%.1f%%", model.snapshot.memoryPercent), "memorychip", .purple)
                Divider().padding(.leading, 38)
                menuMetric("CPU 温度", formatTemperature(model.snapshot.cpuTemperature), "thermometer.medium", .red)
                Divider().padding(.leading, 38)
                menuMetric("风扇", formatFanSpeed(model.snapshot.fanSpeed), "fan.fill", .indigo)
                Divider().padding(.leading, 38)
                menuMetric("实时充电", formatBatteryChargePower(model.snapshot.chargingPower), "battery.100percent.bolt", .mint)
                Divider().padding(.leading, 38)
                menuMetric("网络下载", formatRate(model.snapshot.downloadBytesPerSecond), "arrow.down", .green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("USB-C 与线缆", systemImage: "cable.connector")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(model.snapshot.cableMonitor.activePorts.count)/\(model.snapshot.cableMonitor.ports.count) 已连接")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                if let errorText = model.snapshot.cableMonitor.errorText,
                   model.snapshot.cableMonitor.ports.isEmpty {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else if model.snapshot.cableMonitor.activePorts.isEmpty {
                    Text("没有连接的 USB-C 或雷雳设备")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.cableMonitor.activePorts.prefix(3)) { port in
                        HStack(spacing: 8) {
                            Image(systemName: port.warning == nil ? "cable.connector" : "exclamationmark.triangle.fill")
                                .frame(width: 14)
                                .foregroundStyle(port.warning == nil ? Color.blue : Color.orange)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(port.displayName)
                                    .font(.system(size: 10, weight: .medium))
                                Text(menuCableSubtitle(port))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 8) {
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("打开监控面板", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(action: model.togglePause) {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glass)
                .help(model.isPaused ? "继续监控" : "暂停监控")
            }
            .padding(14)

            Divider()

            HStack {
                Text("只读监控 · 不控制风扇")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private func menuMetric(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(color)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.vertical, 8)
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
    @StateObject private var model = MonitorModel()

    var body: some Scene {
        Window("Mac 资源监控", id: "dashboard") {
            DashboardView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "waveform.path.ecg")
                Text(menuBarSummary(model.snapshot))
                    .monospacedDigit()
            }
            .accessibilityLabel("Mac 资源监控 \(menuBarSummary(model.snapshot))")
        }
        .menuBarExtraStyle(.window)
    }
}

private func menuBarSummary(_ snapshot: ResourceSnapshot) -> String {
    let cpu = "\(Int(snapshot.cpuPercent.rounded()))%"
    guard let temperature = snapshot.cpuTemperature else { return cpu }
    return "\(cpu) · \(Int(temperature.rounded()))°"
}
