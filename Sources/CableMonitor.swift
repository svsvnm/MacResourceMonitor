import Foundation

struct CablePortSnapshot: Identifiable, Equatable {
    let id: String
    let displayName: String
    let type: String
    let connected: Bool
    let stateTitle: String
    let stateDetail: String
    let activeTransports: [String]
    let supportedTransports: [String]
    let cableSpeed: String?
    let cablePower: String?
    let cableVendor: String?
    let cableType: String?
    let trustText: String?
    let negotiatedPower: String?
    let chargerLimit: String?
    let deviceSummary: String?
    let dataLinkSummary: String?
    let warning: String?

    var hasCableIdentity: Bool {
        cableSpeed != nil || cablePower != nil || cableVendor != nil
    }
}

struct CableMonitorSnapshot: Equatable {
    var ports: [CablePortSnapshot] = []
    var helperAvailable = false
    var errorText: String?
    var updatedAt: Date?

    var activePorts: [CablePortSnapshot] { ports.filter(\.connected) }
}

final class CableCollector {
    func collect() -> CableMonitorSnapshot {
        guard let helperURL = helperURL() else {
            return CableMonitorSnapshot(
                helperAvailable: false,
                errorText: "线缆检测组件未安装"
            )
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helperURL
        process.arguments = ["--json", "--no-usb-probe"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LANG": "zh_CN.UTF-8",
            "LC_ALL": "zh_CN.UTF-8"
        ]) { _, new in new }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CableMonitorSnapshot(
                helperAvailable: false,
                errorText: "无法启动线缆检测组件"
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CableMonitorSnapshot(
                helperAvailable: true,
                errorText: message?.isEmpty == false ? message : "读取 USB-C 端口失败"
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let rawPorts = root["ports"] as? [[String: Any]] else {
            return CableMonitorSnapshot(
                helperAvailable: true,
                errorText: "线缆数据格式无法识别"
            )
        }

        let ports = rawPorts.map(parsePort).sorted { lhs, rhs in
            if lhs.connected != rhs.connected { return lhs.connected }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        return CableMonitorSnapshot(
            ports: ports,
            helperAvailable: true,
            errorText: nil,
            updatedAt: Date()
        )
    }

    private func helperURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let packagedHelper = resourceURL.appendingPathComponent("Helpers/whatcable-cli")
        let packagedBundle = resourceURL.appendingPathComponent("WhatCable_WhatCableCore.bundle")
        guard FileManager.default.isExecutableFile(atPath: packagedHelper.path),
              FileManager.default.fileExists(atPath: packagedBundle.path) else { return nil }

        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let stagingDirectory = caches
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "io.github.svsvnm.MacResourceMonitor",
                isDirectory: true
            )
            .appendingPathComponent("WhatCableHelper-82fded6f", isDirectory: true)
        let stagedHelper = stagingDirectory.appendingPathComponent("whatcable-cli")
        let stagedBundle = stagingDirectory.appendingPathComponent("WhatCable_WhatCableCore.bundle")

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: stagedHelper.path) {
                try FileManager.default.copyItem(at: packagedHelper, to: stagedHelper)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: stagedHelper.path
                )
            }
            if !FileManager.default.fileExists(atPath: stagedBundle.path) {
                try FileManager.default.copyItem(at: packagedBundle, to: stagedBundle)
            }
        } catch {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: stagedHelper.path) ? stagedHelper : nil
    }

    private func parsePort(_ raw: [String: Any]) -> CablePortSnapshot {
        let name = string(raw["name"]) ?? "USB-C"
        let type = string(raw["type"]) ?? "USB-C"
        let connected = bool(raw["connectionActive"])
        let transports = dictionary(raw["transports"])
        let active = stringArray(transports["active"])
        let supported = stringArray(transports["supported"])
        let powerSources = dictionaryArray(raw["powerSources"])
        let cable = dictionary(raw["cable"])
        let charging = dictionary(raw["charging"])
        let dataLink = dictionary(raw["dataLink"])
        let trust = dictionary(raw["trust"])
        let device = dictionary(raw["device"])
        let devices = dictionaryArray(raw["devices"])

        let negotiated = powerSources.compactMap { dictionary($0["negotiated"]) }
            .max { number($0["powerW"]) < number($1["powerW"]) }
        let negotiatedPower = negotiated.map {
            String(
                format: "%.0f W · %.1f V · %.1f A",
                number($0["powerW"]), number($0["voltageV"]), number($0["currentA"])
            )
        }
        let maxPower = powerSources.map { int($0["maxPowerW"]) }.max()

        let cableWatts = optionalInt(cable["maxWatts"])
        let cablePower: String?
        if let watts = cableWatts, let current = string(cable["currentRating"]) {
            cablePower = "\(watts) W · \(current)"
        } else if let watts = cableWatts {
            cablePower = "\(watts) W"
        } else {
            cablePower = string(cable["currentRating"])
        }

        let deviceSummary = firstDeviceName(in: devices)
            ?? string(device["vendorName"])
            ?? string(device["kind"])
        let chargerLimit = maxPower.map { "充电器最高 \($0) W" }
        let stateTitle = stateTitle(connected: connected, active: active, hasPower: !powerSources.isEmpty)
        let stateDetail = stateDetail(
            connected: connected,
            active: active,
            usb3Speed: string(transports["usb3Speed"]),
            device: deviceSummary
        )
        let chargingWarning = diagnosticWarning(charging, kind: .charging)
        let dataWarning = diagnosticWarning(dataLink, kind: .data)
        let trustTier = trustText(string(trust["tier"]), contradiction: bool(trust["contradiction"]))
        let trustWarning = bool(trust["contradiction"])
            ? "线缆标称能力与实际协商结果不一致"
            : (string(trust["tier"]) == "red" ? "线缆身份信息存在异常" : nil)

        return CablePortSnapshot(
            id: name,
            displayName: portDisplayName(name: name, type: type),
            type: type,
            connected: connected,
            stateTitle: stateTitle,
            stateDetail: stateDetail,
            activeTransports: active.map(transportLabel),
            supportedTransports: supported.map(transportLabel),
            cableSpeed: string(cable["speed"]),
            cablePower: cablePower,
            cableVendor: string(cable["vendorName"]),
            cableType: cableType(string(cable["type"])),
            trustText: trustTier,
            negotiatedPower: negotiatedPower,
            chargerLimit: chargerLimit,
            deviceSummary: deviceSummary,
            dataLinkSummary: dataLinkSummary(dataLink, active: active, transports: transports),
            warning: chargingWarning ?? dataWarning ?? trustWarning
        )
    }

    private enum DiagnosticKind { case charging, data }

    private func diagnosticWarning(_ diagnostic: [String: Any], kind: DiagnosticKind) -> String? {
        guard bool(diagnostic["isWarning"]) else { return nil }
        switch (kind, string(diagnostic["bottleneck"])) {
        case (.charging, "cableLimit"): return "线缆限制了充电功率"
        case (.charging, "chargerLimit"): return "充电器限制了充电功率"
        case (.charging, "macLimit"): return "Mac 限制了当前充电功率"
        case (.charging, "standbyCharger"): return "此充电器当前处于待机状态"
        case (.data, "cableLimit"): return "线缆限制了数据传输速度"
        case (.data, "deviceLimit"): return "连接设备限制了数据传输速度"
        case (.data, "hostLimit"): return "Mac 端口限制了数据传输速度"
        case (.data, "degraded"): return "数据链路运行速度低于预期"
        case (.data, "blockedBySecurity"): return "配件访问被 macOS 安全策略阻止"
        case (.data, "cableContradictsActive"): return "线缆标称速率与实际链路不一致"
        default: return kind == .charging ? "充电协商存在限制" : "数据链路存在限制"
        }
    }

    private func dataLinkSummary(
        _ diagnostic: [String: Any],
        active: [String],
        transports: [String: Any]
    ) -> String? {
        if let usb3 = string(transports["usb3Speed"]) { return usb3 }
        if active.contains("CIO") { return "Thunderbolt / USB4 链路已建立" }
        if active.contains("USB2") { return "USB 2.0 · 最高 480 Mbps" }
        if active.contains("DisplayPort") { return "DisplayPort 视频链路" }
        guard !diagnostic.isEmpty else { return nil }
        switch string(diagnostic["bottleneck"]) {
        case "fine": return "数据链路运行正常"
        case "deviceLimit": return "速度受连接设备限制"
        case "cableLimit": return "速度受线缆限制"
        case "hostLimit": return "速度受 Mac 端口限制"
        default: return nil
        }
    }

    private func stateTitle(connected: Bool, active: [String], hasPower: Bool) -> String {
        guard connected else { return "未连接" }
        if active.contains("CIO") { return "Thunderbolt / USB4" }
        if active.contains("USB3") { return "USB 3 高速设备" }
        if active.contains("USB2") { return "USB 2 设备" }
        if active.contains("DisplayPort") { return "显示器已连接" }
        if hasPower { return "充电连接" }
        return "已连接"
    }

    private func stateDetail(
        connected: Bool,
        active: [String],
        usb3Speed: String?,
        device: String?
    ) -> String {
        guard connected else { return "插入线缆后显示速率、功率和设备信息" }
        var parts: [String] = []
        if let device { parts.append(device) }
        if let usb3Speed { parts.append(usb3Speed) }
        else if !active.isEmpty { parts.append(active.map(transportLabel).joined(separator: " + ")) }
        return parts.isEmpty ? "正在识别连接和协商状态" : parts.joined(separator: " · ")
    }

    private func portDisplayName(name: String, type: String) -> String {
        let index = name.split(separator: "@").last.map(String.init)
        if type.localizedCaseInsensitiveContains("MagSafe") {
            return index.map { "MagSafe 端口 \($0)" } ?? "MagSafe 端口"
        }
        return index.map { "USB-C 端口 \($0)" } ?? name.replacingOccurrences(of: "Port-", with: "")
    }

    private func transportLabel(_ value: String) -> String {
        switch value {
        case "CIO": return "Thunderbolt/USB4"
        case "USB3": return "USB 3"
        case "USB2": return "USB 2"
        case "DisplayPort": return "DisplayPort"
        case "CC": return "USB-PD"
        default: return value
        }
    }

    private func cableType(_ value: String?) -> String? {
        switch value {
        case "active": return "主动式线缆"
        case "passive": return "被动式线缆"
        default: return nil
        }
    }

    private func trustText(_ tier: String?, contradiction: Bool) -> String? {
        if contradiction { return "能力信息冲突" }
        switch tier {
        case "green": return "线缆能力可信"
        case "amber": return "线缆信息需留意"
        case "red": return "线缆信息异常"
        default: return nil
        }
    }

    private func firstDeviceName(in devices: [[String: Any]]) -> String? {
        for device in devices {
            if let name = string(device["name"]), !name.isEmpty { return name }
            if let child = firstDeviceName(in: dictionaryArray(device["children"])) { return child }
        }
        return nil
    }

    private func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func dictionaryArray(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private func stringArray(_ value: Any?) -> [String] {
        value as? [String] ?? []
    }

    private func string(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }

    private func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private func optionalInt(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}
