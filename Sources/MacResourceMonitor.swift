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
    var expandedMetricsUpdatedAt: Date?
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

    private static let cpuTemperatureKeysByGeneration: [String: [String]] = [
        "m1": [
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D",
            "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"
        ],
        "m2": [
            "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05",
            "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"
        ],
        "m3": [
            "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09",
            "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49",
            "Tf4A", "Tf4B", "Tf4D", "Tf4E"
        ],
        "m4": [
            "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05",
            "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"
        ],
        "m5": [
            "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
            "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
            "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
        ]
    ]

    private let cpuTemperatureKeys = SMCReader.detectedCPUTemperatureKeys()
    private var workingCPUTemperatureKeys: [String]?
    private var cpuTemperatureProbeCounter = 0

    private static func detectedCPUTemperatureKeys() -> [String] {
        guard let brand = cpuBrandString()?.lowercased() else { return [] }
        let words = brand.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for generation in ["m5", "m4", "m3", "m2", "m1"] where words.contains(generation) {
            return cpuTemperatureKeysByGeneration[generation] ?? []
        }
        return []
    }

    private static func cpuBrandString() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname("machdep.cpu.brand_string", bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }

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
        let shouldProbeAllKeys = workingCPUTemperatureKeys == nil || cpuTemperatureProbeCounter == 0
        let candidates = shouldProbeAllKeys
            ? cpuTemperatureKeys
            : workingCPUTemperatureKeys ?? cpuTemperatureKeys
        cpuTemperatureProbeCounter = (cpuTemperatureProbeCounter + 1) % 30
        let readings = candidates.compactMap { key -> (key: String, value: Double)? in
            guard let value = value(for: key),
                  value.isFinite,
                  (10...120).contains(value) else { return nil }
            return (key, value)
        }
        guard !readings.isEmpty,
              let hottest = readings.map(\.value).max() else {
            workingCPUTemperatureKeys = nil
            return nil
        }
        workingCPUTemperatureKeys = readings.map(\.key)
        let values = readings.map(\.value)
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
              output.result == 0,
              output.status == 0,
              output.keyInfo.dataSize > 0,
              output.keyInfo.dataSize <= 32 else { return nil }
        let dataSize = Int(output.keyInfo.dataSize)
        let dataType = string(from: output.keyInfo.dataType)

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5
        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0,
              output.status == 0 else { return nil }

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

private struct ResourceCollectionOptions {
    var includeExpandedMetrics = false
    var includeTopProcesses = false
    var includeCable = false
}

private enum ResourceMonitorConsumer: Hashable {
    case expandedMetrics
    case menuBar
    case processTable
    case cable
}

private final class SystemCollector {
    private var cachedSnapshot = ResourceSnapshot()
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var previousNetwork: (interface: String, received: UInt64, sent: UInt64, date: Date)?
    private var cachedBattery: (text: String, percent: Double?, source: String) = ("检测中", nil, "--")
    private var batterySampleCounter = 0
    private var cableSampleCounter = 0
    private var cachedCableMonitor = CableMonitorSnapshot()
    private let smc = SMCReader()
    private let cableCollector = CableCollector()
    private let chargingPowerReader = ChargingPowerReader()

    func collect(
        options: ResourceCollectionOptions,
        forceCableRefresh: Bool = false,
        forceExpandedMetricsRefresh: Bool = false
    ) -> ResourceSnapshot {
        var snapshot = cachedSnapshot
        snapshot.cpuPercent = sampleCPU()

        let memory = sampleMemory()
        snapshot.memoryUsed = memory.used
        snapshot.memoryTotal = memory.total
        snapshot.memoryPercent = memory.total > 0 ? Double(memory.used) / Double(memory.total) * 100 : 0

        let network = sampleNetwork()
        snapshot.downloadBytesPerSecond = network.receivedPerSecond
        snapshot.uploadBytesPerSecond = network.sentPerSecond
        snapshot.networkInterface = network.interface

        let temperatures = smc.cpuTemperatures()
        snapshot.cpuTemperature = temperatures?.average
        snapshot.hottestCPUTemperature = temperatures?.hottest

        if options.includeExpandedMetrics {
            let disk = sampleDisk()
            snapshot.diskUsed = disk.used
            snapshot.diskTotal = disk.total
            snapshot.diskPercent = disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0

            if forceExpandedMetricsRefresh || batterySampleCounter == 0 {
                cachedBattery = sampleBattery()
                batterySampleCounter = 0
                snapshot.expandedMetricsUpdatedAt = Date()
            }
            batterySampleCounter = (batterySampleCounter + 1) % 5
            snapshot.batteryText = cachedBattery.text
            snapshot.batteryPercent = cachedBattery.percent
            snapshot.powerSource = cachedBattery.source

            let fan = smc.fanReading()
            snapshot.fanSpeed = fan.speed
            snapshot.fanCount = fan.count
            snapshot.thermalState = thermalStateText()
            snapshot.uptime = ProcessInfo.processInfo.systemUptime
            snapshot.chargingPower = chargingPowerReader.read()
        } else {
            batterySampleCounter = 0
        }

        snapshot.processes = options.includeTopProcesses ? sampleTopProcesses() : []

        if options.includeCable || forceCableRefresh {
            if forceCableRefresh || cableSampleCounter == 0 {
                let reading = cableCollector.collect()
                if reading.errorText == nil || cachedCableMonitor.ports.isEmpty {
                    cachedCableMonitor = reading
                } else {
                    cachedCableMonitor.helperAvailable = reading.helperAvailable
                    cachedCableMonitor.errorText = reading.errorText
                }
            }
            cableSampleCounter = (cableSampleCounter + 1) % 3
        } else {
            cableSampleCounter = 0
        }
        snapshot.cableMonitor = cachedCableMonitor
        snapshot.updatedAt = Date()
        cachedSnapshot = snapshot
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
        guard let store = SCDynamicStoreCreate(nil, "MacResourceMonitor" as CFString, nil, nil) else {
            return nil
        }
        for protocolName in ["IPv4", "IPv6"] {
            let key = "State:/Network/Global/\(protocolName)" as CFString
            if let value = SCDynamicStoreCopyValue(store, key) as? [String: Any],
               let interface = value["PrimaryInterface"] as? String,
               !interface.isEmpty {
                return interface
            }
        }
        return nil
    }

    private func interfaceCounters(_ interface: String) -> (received: UInt64, sent: UInt64)? {
        let index = interface.withCString { if_nametoindex($0) }
        guard index > 0 else { return nil }

        var mib = [
            Int32(CTL_NET),
            Int32(PF_LINK),
            Int32(NETLINK_GENERIC),
            Int32(IFMIB_IFDATA),
            Int32(index),
            Int32(IFDATA_GENERAL)
        ]
        var data = ifmibdata()
        var dataSize = MemoryLayout<ifmibdata>.stride
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &data, &dataSize, nil, 0)
        }
        guard result == 0 else { return nil }
        return (UInt64(data.ifmd_data.ifi_ibytes), UInt64(data.ifmd_data.ifi_obytes))
    }

    private func sampleNetwork() -> (receivedPerSecond: Double, sentPerSecond: Double, interface: String) {
        guard let interface = primaryInterface(),
              let counters = interfaceCounters(interface) else {
            previousNetwork = nil
            return (0, 0, "--")
        }

        let now = Date()
        defer {
            previousNetwork = (interface, counters.received, counters.sent, now)
        }
        guard let previous = previousNetwork,
              previous.interface == interface,
              counters.received >= previous.received,
              counters.sent >= previous.sent else {
            return (0, 0, interface)
        }

        let elapsed = max(0.2, now.timeIntervalSince(previous.date))
        let receivedDelta = counters.received - previous.received
        let sentDelta = counters.sent - previous.sent
        return (Double(receivedDelta) / elapsed, Double(sentDelta) / elapsed, interface)
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
    @Published var isRefreshingExpandedMetrics = false

    private let collector = SystemCollector()
    private let queue = DispatchQueue(label: "local.mac-resource-monitor.collector", qos: .utility)
    private var timer: Timer?
    private var refreshInProgress = false
    private var refreshPending = false
    private var forceCableRefreshPending = false
    private var expandedMetricsRefreshGeneration: UInt64 = 0
    private var activeConsumers: Set<ResourceMonitorConsumer> = []

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func setActive(_ active: Bool, for consumer: ResourceMonitorConsumer) {
        updateActiveConsumers([consumer: active])
    }

    func updateActiveConsumers(_ changes: [ResourceMonitorConsumer: Bool]) {
        let previousConsumers = activeConsumers
        for (consumer, active) in changes {
            if active {
                activeConsumers.insert(consumer)
            } else {
                activeConsumers.remove(consumer)
            }
        }
        guard activeConsumers != previousConsumers else { return }

        let newlyActive = activeConsumers.subtracting(previousConsumers)
        let needsCableRefresh = newlyActive.contains(.cable) || newlyActive.contains(.menuBar)
        let expandedBecameActive = newlyActive.contains(.expandedMetrics) || newlyActive.contains(.menuBar)
        let expandedMetricsAreActive = activeConsumers.contains(.expandedMetrics)
            || activeConsumers.contains(.menuBar)
        let expandedMetricsWereActive = previousConsumers.contains(.expandedMetrics)
            || previousConsumers.contains(.menuBar)
        let expandedMetricsAreStale = snapshot.expandedMetricsUpdatedAt.map {
            Date().timeIntervalSince($0) > 4
        } ?? true
        if expandedBecameActive, expandedMetricsAreStale {
            expandedMetricsRefreshGeneration &+= 1
            isRefreshingExpandedMetrics = true
        } else if expandedMetricsWereActive, !expandedMetricsAreActive {
            expandedMetricsRefreshGeneration &+= 1
            isRefreshingExpandedMetrics = false
        }
        refresh(forceCableRefresh: needsCableRefresh)
    }

    func refresh(forceCableRefresh: Bool = false) {
        if forceCableRefresh {
            forceCableRefreshPending = true
            isRefreshingCable = true
        }
        guard !refreshInProgress else {
            refreshPending = true
            return
        }
        let shouldForceCableRefresh = forceCableRefreshPending
        let shouldForceExpandedMetricsRefresh = isRefreshingExpandedMetrics
        let options = collectionOptions
        let expandedMetricsGeneration = expandedMetricsRefreshGeneration
        forceCableRefreshPending = false
        refreshPending = false
        refreshInProgress = true
        queue.async { [weak self] in
            guard let self else { return }
            let next = self.collector.collect(
                options: options,
                forceCableRefresh: shouldForceCableRefresh,
                forceExpandedMetricsRefresh: shouldForceExpandedMetricsRefresh
            )
            DispatchQueue.main.async {
                let nextCPUHistory = Array(self.cpuHistory.suffix(59)) + [next.cpuPercent]
                let nextMemoryHistory = Array(self.memoryHistory.suffix(59)) + [next.memoryPercent]
                self.objectWillChange.send()
                withTransaction(Transaction(animation: nil)) {
                    self.snapshot = next
                    self.cpuHistory = nextCPUHistory
                    self.memoryHistory = nextMemoryHistory
                    self.refreshInProgress = false
                    if options.includeExpandedMetrics,
                       expandedMetricsGeneration == self.expandedMetricsRefreshGeneration {
                        self.isRefreshingExpandedMetrics = false
                    }
                    if shouldForceCableRefresh {
                        self.isRefreshingCable = self.forceCableRefreshPending
                    }
                }
                if self.refreshPending || self.forceCableRefreshPending {
                    self.refresh()
                }
            }
        }
    }

    func refreshCableMonitor() {
        refresh(forceCableRefresh: true)
    }

    private var collectionOptions: ResourceCollectionOptions {
        ResourceCollectionOptions(
            includeExpandedMetrics: activeConsumers.contains(.expandedMetrics)
                || activeConsumers.contains(.menuBar),
            includeTopProcesses: activeConsumers.contains(.processTable),
            includeCable: activeConsumers.contains(.cable)
                || activeConsumers.contains(.menuBar)
        )
    }
}

private struct TelemetryPulseStrip: View {
    let snapshot: ResourceSnapshot
    let isLoadingExpandedMetrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Circle()
                    .fill(InterfacePalette.signal)
                    .frame(width: 7, height: 7)
                    .shadow(color: InterfacePalette.signal.opacity(0.65), radius: 5)
                Text("实时遥测")
                    .font(InterfaceTypography.captionEmphasized)
                Text(
                    isLoadingExpandedMetrics
                        ? "正在更新硬件传感器"
                        : "每 2 秒采样"
                )
                .font(InterfaceTypography.caption)
                .foregroundStyle(.tertiary)
                Spacer()
                Label(snapshot.networkInterface, systemImage: "network")
                    .font(InterfaceTypography.captionMedium)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                TelemetryStripMetric(
                    title: "CPU",
                    value: String(format: "%.0f%%", snapshot.cpuPercent),
                    detail: "处理器负载",
                    color: InterfacePalette.cpuSeries,
                    progress: snapshot.cpuPercent
                )
                stripDivider
                TelemetryStripMetric(
                    title: "内存",
                    value: String(format: "%.0f%%", snapshot.memoryPercent),
                    detail: formatBytes(snapshot.memoryUsed),
                    color: InterfacePalette.memorySeries,
                    progress: snapshot.memoryPercent
                )
                stripDivider
                TelemetryStripMetric(
                    title: "温度",
                    value: formatTemperature(snapshot.cpuTemperature),
                    detail: snapshot.hottestCPUTemperature.map {
                        String(format: "峰值 %.1f°C", $0)
                    } ?? "传感器不可用",
                    color: InterfacePalette.temperature,
                    progress: nil
                )
                stripDivider
                TelemetryStripMetric(
                    title: "下载",
                    value: formatRate(snapshot.downloadBytesPerSecond),
                    detail: "当前接收",
                    color: InterfacePalette.download,
                    progress: nil
                )
                stripDivider
                TelemetryStripMetric(
                    title: "上传",
                    value: formatRate(snapshot.uploadBytesPerSecond),
                    detail: "当前发送",
                    color: InterfacePalette.upload,
                    progress: nil
                )
            }
        }
        .padding(18)
        .stableDashboardCard(cornerRadius: InterfaceMetrics.cardRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("系统实时遥测")
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(InterfacePalette.separator)
            .frame(width: 1, height: 58)
            .padding(.horizontal, 4)
    }
}

private struct TelemetryStripMetric: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(color)
                    .frame(width: 12, height: 3)
                Text(title)
                    .font(InterfaceTypography.captionMedium)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(
                                width: geometry.size.width
                                    * min(1, max(0, progress / 100))
                            )
                    }
                }
                .frame(height: 3)
            } else {
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 3)
            }
            Text(detail)
                .font(InterfaceTypography.microMetadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct CombinedLoadHistory: View {
    let cpuValues: [Double]
    let memoryValues: [Double]
    let cpuValue: Double
    let memoryValue: Double

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoverIndex: Int?
    @State private var accessibilitySampleOffset = 0

    private var sampleCount: Int {
        min(cpuValues.count, memoryValues.count)
    }

    private var accessibilitySampleIndex: Int? {
        guard sampleCount > 0 else { return nil }
        let offset = min(accessibilitySampleOffset, sampleCount - 1)
        return sampleCount - 1 - offset
    }

    private var accessibilitySampleValue: String {
        guard let index = accessibilitySampleIndex else {
            return "暂无历史采样"
        }
        let secondsAgo = (sampleCount - 1 - index) * 2
        let time = secondsAgo == 0 ? "现在" : "约 \(secondsAgo) 秒前"
        return "\(time)，CPU \(Int(cpuValues[index].rounded()))%，内存 \(Int(memoryValues[index].rounded()))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("负载走势")
                        .font(.system(size: 15, weight: .semibold))
                    Text("最近约 2 分钟 · 同一百分比刻度")
                        .font(InterfaceTypography.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                chartLegend("CPU", value: cpuValue, color: InterfacePalette.cpuSeries)
                chartLegend("内存", value: memoryValue, color: InterfacePalette.memorySeries)
            }

            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    chartGrid(in: size)

                    areaPath(values: cpuValues, in: size)
                        .fill(
                            LinearGradient(
                                colors: [
                                    InterfacePalette.cpuSeries.opacity(0.10),
                                    InterfacePalette.cpuSeries.opacity(0.01)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    linePath(values: cpuValues, in: size)
                        .stroke(
                            InterfacePalette.cpuSeries,
                            style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    linePath(values: memoryValues, in: size)
                        .stroke(
                            InterfacePalette.memorySeries,
                            style: StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )

                    if let hoverIndex, sampleCount > 1 {
                        hoverOverlay(index: hoverIndex, in: size)
                    }

                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard sampleCount > 1 else { return }
                                let ratio = min(1, max(0, location.x / size.width))
                                hoverIndex = min(
                                    sampleCount - 1,
                                    max(0, Int((ratio * CGFloat(sampleCount - 1)).rounded()))
                                )
                            case .ended:
                                hoverIndex = nil
                            }
                        }
                }
            }
            .frame(height: 170)
            .clipped()

            HStack {
                Text("2 分钟前")
                Spacer()
                Text("浏览采样详情")
                Spacer()
                Text("现在")
            }
            .font(InterfaceTypography.microMetadata)
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 268, alignment: .topLeading)
        .stableDashboardCard(cornerRadius: InterfaceMetrics.cardRadius)
        .transaction { transaction in
            transaction.animation = nil
        }
        .onChange(of: sampleCount) { _, newCount in
            accessibilitySampleOffset = min(
                accessibilitySampleOffset,
                max(0, newCount - 1)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CPU 与内存负载趋势")
        .accessibilityValue(accessibilitySampleValue)
        .accessibilityHint("向上浏览较新的采样，向下浏览较早的采样")
        .accessibilityAdjustableAction { direction in
            guard sampleCount > 0 else { return }
            switch direction {
            case .increment:
                accessibilitySampleOffset = max(
                    0,
                    accessibilitySampleOffset - 1
                )
            case .decrement:
                accessibilitySampleOffset = min(
                    sampleCount - 1,
                    accessibilitySampleOffset + 1
                )
            @unknown default:
                break
            }
        }
    }

    private func chartLegend(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(color)
                .frame(width: 16, height: 3)
            Text(title)
                .font(InterfaceTypography.captionMedium)
            Text("\(Int(value.rounded()))%")
                .font(InterfaceTypography.compactValue)
                .foregroundStyle(.secondary)
        }
    }

    private func chartGrid(in size: CGSize) -> some View {
        ZStack {
            ForEach(0...4, id: \.self) { step in
                Path { path in
                    let y = size.height * CGFloat(step) / 4
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(InterfacePalette.chartGrid, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func hoverOverlay(index: Int, in size: CGSize) -> some View {
        let x = size.width * CGFloat(index) / CGFloat(max(1, sampleCount - 1))
        let cpu = cpuValues[index]
        let memory = memoryValues[index]
        let cpuY = chartY(cpu, height: size.height)
        let memoryY = chartY(memory, height: size.height)
        let surface = InterfacePalette.stableDashboardSurface(for: colorScheme)

        Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        .stroke(InterfacePalette.crosshair, lineWidth: 1)

        Circle()
            .fill(InterfacePalette.cpuSeries)
            .overlay(Circle().stroke(surface, lineWidth: 2))
            .frame(width: 9, height: 9)
            .position(x: x, y: cpuY)

        Circle()
            .fill(InterfacePalette.memorySeries)
            .overlay(Circle().stroke(surface, lineWidth: 2))
            .frame(width: 9, height: 9)
            .position(x: x, y: memoryY)

        VStack(alignment: .leading, spacing: 3) {
            Text("CPU  \(Int(cpu.rounded()))%")
            Text("内存  \(Int(memory.rounded()))%")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: InterfaceMetrics.controlRadius,
                style: .continuous
            )
        )
        .position(
            x: min(max(58, x), max(58, size.width - 58)),
            y: 27
        )
    }

    private func linePath(values: [Double], in size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (index, rawValue) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = chartY(rawValue, height: size.height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func areaPath(values: [Double], in size: CGSize) -> Path {
        var path = linePath(values: values, in: size)
        guard values.count > 1 else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private func chartY(_ value: Double, height: CGFloat) -> CGFloat {
        height * (1 - CGFloat(min(100, max(0, value)) / 100))
    }
}

private struct HardwareTelemetryPanel: View {
    let snapshot: ResourceSnapshot
    let isLoadingExpandedMetrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("硬件与电源")
                    .font(.system(size: 15, weight: .semibold))
                Text(isLoadingExpandedMetrics ? "正在读取传感器" : "最近一次完整采样")
                    .font(InterfaceTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 13)

            hardwareRow(
                "磁盘",
                isLoadingExpandedMetrics
                    ? "--"
                    : "\(Int(snapshot.diskPercent.rounded()))% 已用",
                symbol: "internaldrive",
                color: InterfacePalette.storage,
                progress: isLoadingExpandedMetrics ? nil : snapshot.diskPercent
            )
            rowDivider
            hardwareRow(
                "风扇",
                isLoadingExpandedMetrics ? "--" : formatFanSpeed(snapshot.fanSpeed),
                symbol: "fan.fill",
                color: InterfacePalette.fan
            )
            rowDivider
            hardwareRow(
                "电池",
                isLoadingExpandedMetrics ? "检测中" : snapshot.batteryText,
                symbol: "battery.75percent",
                color: InterfacePalette.battery
            )
            rowDivider
            hardwareRow(
                "充电功率",
                isLoadingExpandedMetrics
                    ? "--"
                    : formatBatteryChargePower(snapshot.chargingPower),
                symbol: "bolt.fill",
                color: InterfacePalette.power
            )
            rowDivider
            hardwareRow(
                "热状态",
                isLoadingExpandedMetrics ? "检测中" : snapshot.thermalState,
                symbol: "thermometer.medium",
                color: InterfacePalette.temperature
            )
        }
        .padding(18)
        .frame(width: 320, alignment: .topLeading)
        .frame(minHeight: 268, alignment: .topLeading)
        .stableDashboardCard(cornerRadius: InterfaceMetrics.cardRadius)
    }

    private func hardwareRow(
        _ label: String,
        _ value: String,
        symbol: String,
        color: Color,
        progress: Double? = nil
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(InterfaceTypography.captionEmphasized)
                    .foregroundStyle(color)
                    .frame(width: 17)
                Text(label)
                    .font(InterfaceTypography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(InterfaceTypography.captionMedium)
                    .lineLimit(1)
            }
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(color.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(
                                width: geometry.size.width
                                    * min(1, max(0, progress / 100))
                            )
                    }
                }
                .frame(height: 3)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 8)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(InterfacePalette.separator)
            .frame(height: 1)
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
            .font(InterfaceTypography.captionMedium)
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
                    .font(.system(size: 13, design: .rounded))
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
    let isLoadingExpandedMetrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("系统状态").font(.system(size: 14, weight: .semibold))
            detail("网络接口", snapshot.networkInterface, "network")
            Divider().opacity(0.45)
            detail("供电方式", isLoadingExpandedMetrics ? "检测中" : snapshot.powerSource, "bolt.fill")
            Divider().opacity(0.45)
            detail("电池状态", isLoadingExpandedMetrics ? "检测中" : snapshot.batteryText, "battery.75percent")
            Divider().opacity(0.45)
            detail("系统热状态", isLoadingExpandedMetrics ? "检测中" : snapshot.thermalState, "thermometer.medium")
            Divider().opacity(0.45)
            detail("运行时间", isLoadingExpandedMetrics ? "检测中" : formatUptime(snapshot.uptime), "clock.arrow.circlepath")
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
            Text(label).font(InterfaceTypography.body).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(InterfaceTypography.bodyEmphasized)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
        }
    }
}

private struct CableSection: View {
    let monitor: CableMonitorSnapshot
    let chargingPower: ChargingPowerSnapshot
    let isRefreshing: Bool

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
                if isRefreshing {
                    Label("正在检测", systemImage: "arrow.triangle.2.circlepath")
                        .font(InterfaceTypography.captionMedium)
                        .foregroundStyle(.blue)
                } else if let errorText = monitor.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(InterfaceTypography.captionMedium)
                        .foregroundStyle(.orange)
                } else {
                    Text("检测到 \(monitor.ports.count) 个端口 · \(monitor.activePorts.count) 个已连接")
                        .font(InterfaceTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isRefreshing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("正在重新检测 USB-C 与线缆状态")
                            .font(.system(size: 13, weight: .medium))
                        Text("检测组件完成后会显示最新端口数据")
                            .font(InterfaceTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .glassEffect(
                    .clear,
                    in: RoundedRectangle(cornerRadius: InterfaceMetrics.cardRadius, style: .continuous)
                )
            } else if monitor.ports.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(monitor.errorText ?? "没有发现可读取的 USB-C 端口")
                            .font(.system(size: 13, weight: .medium))
                        Text("该功能需要 Apple 芯片和 macOS 14 或更高版本")
                            .font(InterfaceTypography.caption)
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
                .font(InterfaceTypography.caption)
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
    let isRefreshing: Bool

    var body: some View {
        CableSection(
            monitor: monitor,
            chargingPower: chargingPower,
            isRefreshing: isRefreshing
        )
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
                    RoundedRectangle(
                        cornerRadius: InterfaceMetrics.controlRadius,
                        style: .continuous
                    )
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
                        .font(InterfaceTypography.captionMedium)
                        .foregroundStyle(accent)
                }
                Spacer()
                Circle()
                    .fill(port.connected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }

            Text(port.stateDetail)
                .font(InterfaceTypography.caption)
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
                                .font(InterfaceTypography.captionMedium)
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                        .padding(.top, 2)
                    }
                    if !port.hasCableIdentity {
                        Text("macOS 尚未读取到线缆 E-Marker；普通 3A 或仅充电线缆可能不提供该信息。")
                            .font(InterfaceTypography.microMetadata)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text(port.supportedTransports.isEmpty
                     ? (port.type.localizedCaseInsensitiveContains("MagSafe") ? "磁吸充电端口" : "当前无传输能力数据")
                     : "支持：\(port.supportedTransports.joined(separator: " · "))")
                    .font(InterfaceTypography.microMetadata)
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
                .font(InterfaceTypography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
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
        case .monitor: return "SYSTEM / LIVE"
        case .traffic: return "NETWORK / PROCESS"
        case .ports: return "PORTS / POWER"
        case .cleanup: return "STORAGE / ANALYSIS"
        case .uninstall: return "APPS / MANAGEMENT"
        }
    }
}

enum InterfaceMetrics {
    static let shellRadius: CGFloat = 20
    static let panelRadius: CGFloat = 16
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9
    static let compactRadius: CGFloat = 5
    static let shellInset: CGFloat = 14
    static let sidebarWidth: CGFloat = 214
}

enum InterfaceTypography {
    static let microMetadata = Font.system(size: 11, weight: .medium)
    static let microEmphasized = Font.system(size: 11, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let captionEmphasized = Font.system(size: 12, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyEmphasized = Font.system(size: 13, weight: .semibold)
    static let compactValue = Font.system(size: 13, weight: .semibold, design: .monospaced)
}

enum InterfacePalette {
    // The palette follows the app icon: cool telemetry blue with one magenta
    // comparison series. Large surfaces stay neutral so live data carries color.
    static let accent = Color(red: 0.000, green: 0.404, blue: 0.851)
    static let signal = Color(red: 0.000, green: 0.650, blue: 0.780)
    static let cpuSeries = Color(red: 0.000, green: 0.404, blue: 0.851)
    static let memorySeries = Color(red: 0.722, green: 0.231, blue: 0.561)
    static let temperature = Color(red: 0.835, green: 0.235, blue: 0.190)
    static let download = Color(red: 0.060, green: 0.505, blue: 0.330)
    static let upload = Color(red: 0.115, green: 0.420, blue: 0.825)
    static let storage = Color(red: 0.690, green: 0.380, blue: 0.045)
    static let fan = Color(red: 0.415, green: 0.330, blue: 0.745)
    static let battery = Color(red: 0.130, green: 0.570, blue: 0.350)
    static let power = Color(red: 0.680, green: 0.470, blue: 0.030)

    static let iconSurface = Color.primary.opacity(0.055)
    static let cardStroke = Color.primary.opacity(0.080)
    static let separator = Color.primary.opacity(0.075)
    static let chartGrid = Color.primary.opacity(0.060)
    static let crosshair = Color.primary.opacity(0.28)

    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.040, green: 0.050, blue: 0.064)
            : Color(red: 0.945, green: 0.955, blue: 0.968)
    }

    static func sidebarSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.066, blue: 0.082)
            : Color(red: 0.975, green: 0.980, blue: 0.987)
    }

    static func glassSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.088, blue: 0.108).opacity(0.74)
            : Color.white.opacity(0.42)
    }

    static func stableSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.070, green: 0.082, blue: 0.100).opacity(0.86)
            : Color.white.opacity(0.34)
    }

    static func stableDashboardSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.082, green: 0.096, blue: 0.118).opacity(0.90)
            : Color.white.opacity(0.50)
    }

    static func menuSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.065, green: 0.078, blue: 0.096)
            : Color(red: 0.970, green: 0.978, blue: 0.988)
    }
}

struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(InterfacePalette.glassSurface(for: colorScheme), in: shape)
            .overlay(shape.stroke(InterfacePalette.cardStroke, lineWidth: 0.6))
            .clipShape(shape)
    }
}

struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let isDense: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .glassEffect(isDense ? .regular : .clear, in: shape)
            .overlay(
                shape.stroke(
                    InterfacePalette.cardStroke.opacity(isDense ? 0.45 : 0.70),
                    lineWidth: 0.6
                )
            )
            .clipShape(shape)
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
            .overlay(shape.stroke(InterfacePalette.cardStroke, lineWidth: 0.6))
            .clipShape(shape)
            .shadow(color: Color.black.opacity(0.018), radius: 8, y: 2)
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

    func liquidGlassPanel(
        cornerRadius: CGFloat = InterfaceMetrics.panelRadius,
        isDense: Bool = false
    ) -> some View {
        modifier(
            LiquidGlassPanelModifier(
                cornerRadius: cornerRadius,
                isDense: isDense
            )
        )
    }

    func stableListCard(
        cornerRadius: CGFloat = InterfaceMetrics.cardRadius
    ) -> some View {
        modifier(StableListCardModifier(cornerRadius: cornerRadius))
    }

    func stableDashboardCard(
        cornerRadius: CGFloat = InterfaceMetrics.cardRadius
    ) -> some View {
        modifier(StableDashboardCardModifier(cornerRadius: cornerRadius))
    }

    func stableMenuCard(
        cornerRadius: CGFloat = InterfaceMetrics.cardRadius
    ) -> some View {
        modifier(StableMenuCardModifier(cornerRadius: cornerRadius))
    }
}

private struct SidebarNavigationItem: View {
    let section: DashboardSection
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? section.tint : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(section.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    Text(section.subtitle)
                        .font(InterfaceTypography.microMetadata)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? section.tint.opacity(0.11)
                    : Color.primary.opacity(isHovering ? 0.040 : 0),
                in: RoundedRectangle(
                    cornerRadius: InterfaceMetrics.controlRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(section.tint)
                        .frame(width: 3, height: 24)
                        .offset(x: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var processNetworkModel: ProcessNetworkMonitor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var storageModel = StorageManager()
    @State private var selectedSection: DashboardSection = .monitor
    @State private var storagePage: StoragePage = .overview

    var body: some View {
        ZStack {
            ambientBackground
            HStack(spacing: 0) {
                sidebar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        contentHeader
                        sectionContent
                    }
                    .padding(.top, 30)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 24)
                }
                .scrollClipDisabled(false)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .id("\(selectedSection.id)-\(storagePage.rawValue)")
            }
        }
        .frame(minWidth: 1060, idealWidth: 1180, minHeight: 720, idealHeight: 840)
        .background(WindowTransparencyConfigurator())
        .onAppear {
            updateResourceConsumers()
        }
        .onChange(of: selectedSection) { _, _ in
            updateResourceConsumers()
        }
        .onDisappear {
            model.updateActiveConsumers([
                .expandedMetrics: false,
                .processTable: false,
                .cable: false
            ])
        }
    }

    private func updateResourceConsumers() {
        model.updateActiveConsumers([
            .expandedMetrics: selectedSection == .monitor || selectedSection == .ports,
            .processTable: selectedSection == .monitor,
            .cable: selectedSection == .ports
        ])
    }

    @ViewBuilder
    private var sectionContent: some View {
        if selectedSection == .monitor {
            VStack(spacing: 14) {
                TelemetryPulseStrip(
                    snapshot: model.snapshot,
                    isLoadingExpandedMetrics: model.isRefreshingExpandedMetrics
                )

                HStack(alignment: .top, spacing: 14) {
                    CombinedLoadHistory(
                        cpuValues: model.cpuHistory,
                        memoryValues: model.memoryHistory,
                        cpuValue: model.snapshot.cpuPercent,
                        memoryValue: model.snapshot.memoryPercent
                    )
                    HardwareTelemetryPanel(
                        snapshot: model.snapshot,
                        isLoadingExpandedMetrics: model.isRefreshingExpandedMetrics
                    )
                }

                HStack(alignment: .top, spacing: 14) {
                    ProcessTable(rows: model.snapshot.processes)
                    SystemDetails(
                        snapshot: model.snapshot,
                        isLoadingExpandedMetrics: model.isRefreshingExpandedMetrics
                    )
                }
            }
        } else if selectedSection == .traffic {
            ProcessTrafficView(model: processNetworkModel)
        } else if selectedSection == .ports {
            PortMonitorView(
                monitor: model.snapshot.cableMonitor,
                chargingPower: model.isRefreshingExpandedMetrics
                    ? ChargingPowerSnapshot()
                    : model.snapshot.chargingPower,
                isRefreshing: model.isRefreshingCable
            )
        } else if selectedSection == .cleanup {
            StorageCleanupView(model: storageModel, selectedPage: $storagePage)
        } else {
            AppUninstallerView(model: storageModel)
        }
    }

    private var ambientBackground: some View {
        ZStack {
            InterfacePalette.canvas(for: colorScheme)
                .opacity(
                    reduceTransparency
                        ? 1
                        : (colorScheme == .dark ? 0.94 : 0.96)
                )
            LinearGradient(
                colors: [
                    InterfacePalette.accent.opacity(colorScheme == .dark ? 0.050 : 0.030),
                    Color.clear,
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac 资源监控")
                        .font(.system(size: 14, weight: .semibold))
                    Text("SYSTEM TELEMETRY")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.tertiary)
                }
            }

            sidebarGroupLabel("概览")
                .padding(.top, 28)

            VStack(spacing: 4) {
                sidebarItem(.monitor)
                sidebarItem(.traffic)
            }

            sidebarGroupLabel("工具")
                .padding(.top, 18)

            VStack(spacing: 4) {
                sidebarItem(.ports)
                sidebarItem(.cleanup)
                sidebarItem(.uninstall)
            }

            Spacer()

            Capsule()
                .fill(InterfacePalette.separator)
                .frame(height: 1)
                .padding(.bottom, 13)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(InterfacePalette.download)
                        .frame(width: 7, height: 7)
                    Text("后台采集中")
                        .font(InterfaceTypography.captionEmphasized)
                    Spacer()
                    Text(model.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.0f%%", model.snapshot.cpuPercent))
                        .font(.system(size: 20, weight: .semibold))
                    Text("CPU")
                        .font(InterfaceTypography.microMetadata)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "thermometer.medium")
                        .font(InterfaceTypography.captionEmphasized)
                        .foregroundStyle(InterfacePalette.temperature)
                    Text(formatTemperature(model.snapshot.cpuTemperature))
                        .font(InterfaceTypography.captionMedium)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 22)
        .padding(.bottom, 15)
        .frame(width: InterfaceMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .liquidGlassPanel(
            cornerRadius: InterfaceMetrics.shellRadius,
            isDense: true
        )
        .padding(.leading, InterfaceMetrics.shellInset)
        .padding(.vertical, InterfaceMetrics.shellInset)
    }

    private func sidebarGroupLabel(_ title: String) -> some View {
        Text(title)
            .font(InterfaceTypography.microEmphasized)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 7)
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
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(
                    cornerRadius: InterfaceMetrics.controlRadius,
                    style: .continuous
                )
                .fill(selectedSection.tint.opacity(0.10))
                Image(systemName: selectedSection.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(selectedSection.tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(heroTitle)
                    .font(.system(size: 21, weight: .semibold))
                Text(headerSubtitle)
                    .font(InterfaceTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(selectedSection.tint)
                        .frame(width: 6, height: 6)
                    Text(heroStatusDetail)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(heroFootnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .font(InterfaceTypography.microMetadata)
            }

            Spacer(minLength: 14)

            VStack(alignment: .trailing, spacing: 1) {
                Text(heroValue)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                Text(heroValueLabel)
                    .font(InterfaceTypography.microMetadata)
                    .foregroundStyle(.tertiary)
            }

            Button(action: performHeroAction) {
                Label(heroActionTitle, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glassProminent)
            .tint(selectedSection.tint)
            .disabled(isHeroActionDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .liquidGlassPanel(cornerRadius: InterfaceMetrics.panelRadius)
    }

    private var heroTitle: String {
        switch selectedSection {
        case .monitor:
            if (!model.isRefreshingExpandedMetrics && model.snapshot.thermalState != "正常")
                || model.snapshot.cpuPercent >= 85
                || model.snapshot.memoryPercent >= 90 {
                return "系统负载需要关注"
            }
            return "系统运行正常"
        case .traffic: return "进程网络活动"
        case .ports:
            if model.isRefreshingCable { return "正在检测接口" }
            return model.snapshot.cableMonitor.errorText == nil
                ? "接口与供电状态"
                : "接口数据需要重新检测"
        case .cleanup: return "存储空间分析"
        case .uninstall: return "已安装应用"
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
        case .monitor:
            if model.isRefreshingExpandedMetrics { return "正在更新磁盘、风扇和电源信息" }
            let date = model.snapshot.expandedMetricsUpdatedAt ?? model.snapshot.updatedAt
            return "最近更新 \(date.formatted(date: .omitted, time: .shortened))"
        case .traffic:
            if let date = processNetworkModel.lastUpdatedAt {
                return "最近采样 \(date.formatted(date: .omitted, time: .standard))"
            }
            return processNetworkModel.errorText ?? "正在建立流量基线"
        case .ports:
            if model.isRefreshingCable { return "正在运行接口检测组件" }
            if let error = model.snapshot.cableMonitor.errorText {
                return error
            }
            if let date = model.snapshot.cableMonitor.updatedAt {
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
        case .ports:
            guard !model.isRefreshingCable,
                  model.snapshot.cableMonitor.errorText == nil else { return "--" }
            return "\(model.snapshot.cableMonitor.activePorts.count) 个"
        case .cleanup: return formatStorageBytes(storageModel.diskAvailable)
        case .uninstall: return "\(storageModel.installedApplications.count) 个"
        }
    }

    private var heroValueLabel: String {
        switch selectedSection {
        case .monitor: return "当前 CPU 温度"
        case .traffic: return "↑ \(formatRate(processNetworkModel.uploadBytesPerSecond))"
        case .ports:
            if model.isRefreshingCable { return "正在检测" }
            return model.snapshot.cableMonitor.errorText == nil
                ? "已连接端口"
                : "上次结果可能已过期"
        case .cleanup: return "磁盘可用空间"
        case .uninstall: return "已识别第三方应用"
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
    var traffic = ProcessTrafficDisplayState()
}

private struct MenuBarPanel: View {
    @ObservedObject var model: MonitorModel
    let processNetworkModel: ProcessNetworkMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var presentation = MenuBarPresentationState()

    var body: some View {
        VStack(spacing: 0) {
            menuHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            menuDivider

            primaryVitals
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            menuDivider

            processTrafficRanking
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

            menuDivider

            hardwareSummary
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

            menuDivider

            menuFooter
                .padding(12)
        }
        .frame(width: 360)
        .liquidGlassPanel(
            cornerRadius: InterfaceMetrics.shellRadius,
            isDense: true
        )
        .background(WindowTransparencyConfigurator())
        .onAppear {
            presentation = MenuBarPresentationState(
                traffic: processNetworkModel.displayState
            )
            model.setActive(true, for: .menuBar)
            processNetworkModel.setActive(true, for: .menuBar)
        }
        .onDisappear {
            model.setActive(false, for: .menuBar)
            processNetworkModel.setActive(false, for: .menuBar)
        }
        .onReceive(processNetworkModel.$displayState) { traffic in
            presentation = MenuBarPresentationState(
                traffic: traffic
            )
        }
    }

    private var snapshot: ResourceSnapshot { model.snapshot }
    private var menuTraffic: ProcessTrafficDisplayState { presentation.traffic }

    private var menuHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mac 资源监控")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(healthStatusColor)
                        .frame(width: 6, height: 6)
                    Text(healthStatusTitle)
                        .font(InterfaceTypography.microMetadata)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(
                    model.isRefreshingExpandedMetrics
                        ? "更新中"
                        : snapshot.updatedAt.formatted(
                            date: .omitted,
                            time: .shortened
                        )
                )
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                Text(snapshot.networkInterface)
                    .font(InterfaceTypography.microMetadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var primaryVitals: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                HStack(alignment: .top, spacing: 9) {
                    Capsule()
                        .fill(InterfacePalette.temperature)
                        .frame(width: 3, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU 温度")
                            .font(InterfaceTypography.microMetadata)
                            .foregroundStyle(.secondary)
                        Text(formatTemperature(snapshot.cpuTemperature))
                            .font(.system(size: 27, weight: .semibold))
                            .lineLimit(1)
                        Text(
                            snapshot.hottestCPUTemperature.map {
                                String(format: "峰值 %.1f°C", $0)
                            } ?? "传感器不可用"
                        )
                        .font(InterfaceTypography.microMetadata)
                        .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 2)

                VStack(spacing: 9) {
                    menuLoadMetric(
                        "CPU",
                        value: snapshot.cpuPercent,
                        color: InterfacePalette.cpuSeries
                    )
                    menuLoadMetric(
                        "内存",
                        value: snapshot.memoryPercent,
                        color: InterfacePalette.memorySeries
                    )
                }
                .frame(width: 112)
            }

            HStack(spacing: 12) {
                menuNetworkMetric(
                    "下载",
                    value: snapshot.downloadBytesPerSecond,
                    symbol: "arrow.down",
                    color: InterfacePalette.download
                )
                Rectangle()
                    .fill(InterfacePalette.separator)
                    .frame(width: 1, height: 28)
                menuNetworkMetric(
                    "上传",
                    value: snapshot.uploadBytesPerSecond,
                    symbol: "arrow.up",
                    color: InterfacePalette.upload
                )
            }
            .padding(.top, 2)
        }
    }

    private func menuLoadMetric(
        _ title: String,
        value: Double,
        color: Color
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                HStack(spacing: 5) {
                    Capsule()
                        .fill(color)
                        .frame(width: 10, height: 3)
                    Text(title)
                        .font(InterfaceTypography.microMetadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(value.rounded()))%")
                    .font(InterfaceTypography.compactValue)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.13))
                    Capsule()
                        .fill(color)
                        .frame(
                            width: geometry.size.width
                                * min(1, max(0, value / 100))
                        )
                }
            }
            .frame(height: 3)
        }
    }

    private func menuNetworkMetric(
        _ title: String,
        value: Double,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(InterfaceTypography.microMetadata)
                    .foregroundStyle(.tertiary)
                Text(formatRate(value))
                    .font(InterfaceTypography.compactValue)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var topTrafficRows: [ProcessTrafficRow] {
        Array(
            menuTraffic.rows
                .filter { $0.currentBytesPerSecond > 0 }
                .sorted { $0.currentBytesPerSecond > $1.currentBytesPerSecond }
                .prefix(3)
        )
    }

    private var processTrafficRanking: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Text("活跃进程")
                    .font(InterfaceTypography.captionEmphasized)
                Spacer()
                Text(
                    "↓\(formatMenuBarRate(menuTraffic.downloadBytesPerSecond))  "
                        + "↑\(formatMenuBarRate(menuTraffic.uploadBytesPerSecond))"
                )
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            if let error = menuTraffic.errorText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(InterfaceTypography.microEmphasized)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(InterfaceTypography.microMetadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 25)
            } else if topTrafficRows.isEmpty {
                HStack(spacing: 8) {
                    if menuTraffic.lastUpdatedAt == nil {
                        ProgressView()
                            .controlSize(.mini)
                        Text("正在建立进程流量基线")
                            .font(InterfaceTypography.microMetadata)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(InterfaceTypography.microEmphasized)
                            .foregroundStyle(.secondary)
                        Text("当前没有活跃进程流量")
                            .font(InterfaceTypography.microMetadata)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 25)
            } else {
                ForEach(topTrafficRows) { row in
                    menuTrafficRow(row)
                }
            }
        }
    }

    private func menuTrafficRow(_ row: ProcessTrafficRow) -> some View {
        HStack(spacing: 8) {
            menuTrafficIcon(pid: row.pid, name: row.name)

            Text(row.name)
                .font(InterfaceTypography.microMetadata)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .foregroundStyle(InterfacePalette.download)
                Text(formatMenuBarRate(row.downloadBytesPerSecond))
            }
            .frame(width: 54, alignment: .trailing)
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .foregroundStyle(InterfacePalette.upload)
                Text(formatMenuBarRate(row.uploadBytesPerSecond))
            }
            .frame(width: 54, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    @ViewBuilder
    private func menuTrafficIcon(pid: Int32, name: String) -> some View {
        if let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            RoundedRectangle(
                cornerRadius: InterfaceMetrics.compactRadius,
                style: .continuous
            )
            .fill(InterfacePalette.iconSurface)
                .overlay {
                    Text(String(name.prefix(1)).uppercased())
                        .font(InterfaceTypography.microEmphasized)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 20, height: 20)
        }
    }

    private var hardwareSummary: some View {
        HStack(spacing: 0) {
            menuHardwareMetric(
                title: "风扇",
                value: model.isRefreshingExpandedMetrics
                    ? "--"
                    : compactFanSpeed(snapshot.fanSpeed),
                detail: snapshot.fanCount > 0 ? "\(snapshot.fanCount) 个" : "未检测",
                symbol: "fan.fill",
                color: InterfacePalette.fan
            )
            hardwareDivider
            menuHardwareMetric(
                title: "电源",
                value: model.isRefreshingExpandedMetrics
                    ? "--"
                    : formatBatteryChargePower(snapshot.chargingPower),
                detail: model.isRefreshingExpandedMetrics
                    ? "读取中"
                    : snapshot.powerSource,
                symbol: "bolt.fill",
                color: InterfacePalette.power
            )
            hardwareDivider
            menuHardwareMetric(
                title: "接口",
                value: model.isRefreshingCable
                    ? "--"
                    : "\(snapshot.cableMonitor.activePorts.count) 个",
                detail: portStatusDetail,
                symbol: "cable.connector",
                color: portStatusColor
            )
        }
    }

    private func menuHardwareMetric(
        title: String,
        value: String,
        detail: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(InterfaceTypography.microEmphasized)
                    .foregroundStyle(color)
                Text(title)
                    .font(InterfaceTypography.microMetadata)
                    .foregroundStyle(.tertiary)
            }
            Text(value)
                .font(InterfaceTypography.captionEmphasized)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(InterfaceTypography.microMetadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
    }

    private var hardwareDivider: some View {
        Rectangle()
            .fill(InterfacePalette.separator)
            .frame(width: 1, height: 42)
    }

    private var menuFooter: some View {
        HStack(spacing: 10) {
            Button {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("打开面板", systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            .tint(InterfacePalette.accent)

            Spacer()

            Text("只读 · 2 秒更新")
                .font(InterfaceTypography.microMetadata)
                .foregroundStyle(.tertiary)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("退出 Mac 资源监控")
        }
    }

    private var menuDivider: some View {
        Rectangle()
            .fill(InterfacePalette.separator)
            .frame(height: 1)
    }

    private var healthStatusTitle: String {
        if snapshot.cpuPercent >= 85
            || snapshot.memoryPercent >= 90
            || (!model.isRefreshingExpandedMetrics
                && snapshot.thermalState != "正常") {
            return "需要关注"
        }
        return "系统运行正常"
    }

    private var healthStatusColor: Color {
        healthStatusTitle == "系统运行正常"
            ? InterfacePalette.download
            : .orange
    }

    private var portStatusDetail: String {
        if model.isRefreshingCable { return "检测中" }
        if snapshot.cableMonitor.errorText != nil { return "需刷新" }
        return snapshot.cableMonitor.activePorts.first?.displayName ?? "未连接"
    }

    private var portStatusColor: Color {
        if snapshot.cableMonitor.errorText != nil { return .orange }
        return InterfacePalette.accent
    }
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

private func formatFanSpeed(_ value: Double?) -> String {
    guard let value else { return "不可用" }
    return "\(Int(value.rounded())) RPM"
}

private func formatBatteryChargePower(_ power: ChargingPowerSnapshot) -> String {
    guard power.externalConnected else { return "未接电源" }
    guard power.isCharging else { return "未充电" }
    guard let watts = power.batteryChargeWatts else { return "检测中" }
    return String(format: "%.1f W", watts)
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
