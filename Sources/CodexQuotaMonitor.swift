import Foundation
import Combine
import Darwin

struct CodexQuotaWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Date?
    let isSyntheticPlaceholder: Bool?

    var remainingPercent: Double? {
        guard isSyntheticPlaceholder != true, let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }

    var periodTitle: String {
        guard let minutes = windowMinutes, minutes > 0 else { return "额度窗口" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}

struct CodexQuotaSnapshot: Equatable, Sendable {
    let primary: CodexQuotaWindow?
    let secondary: CodexQuotaWindow?
    let plan: String?
    let updatedAt: Date
}

enum CodexQuotaError: Error, Equatable, LocalizedError {
    case missingHelper, loginRequired, unavailable, timedOut, invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingHelper: return "额度组件缺失，请重新安装应用。"
        case .loginRequired: return "需要 Codex 登录授权。请在 Codex 中完成登录，再点击刷新。"
        case .unavailable: return "暂时无法读取订阅额度，请检查网络及 Codex 登录状态后重试。"
        case .timedOut: return "额度查询超时，请稍后重试。"
        case .invalidResponse: return "当前账号未返回可识别的订阅额度。请确认使用的是订阅账号。"
        }
    }
}

enum CodexQuotaParser {
    private struct Payload: Decodable {
        let provider: String
        let usage: Usage?
        let error: Failure?
    }
    private struct Usage: Decodable {
        let primary: CodexQuotaWindow?
        let secondary: CodexQuotaWindow?
        let identity: Identity?
    }
    private struct Identity: Decodable { let loginMethod: String? }
    private struct Failure: Decodable { let message: String? }

    static func parse(_ data: Data, receivedAt: Date = Date()) throws -> CodexQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw CodexQuotaError.invalidResponse }
            return date
        }
        let payloads: [Payload]
        do { payloads = try decoder.decode([Payload].self, from: data) }
        catch { throw CodexQuotaError.invalidResponse }
        guard let payload = payloads.first(where: { $0.provider == "codex" }) else {
            throw CodexQuotaError.invalidResponse
        }
        if let failure = payload.error {
            // Never publish raw helper errors, which may contain account or credential details.
            let message = (failure.message ?? "").lowercased()
            if ["login", "sign in", "sign-in", "unauthorized", "credential", "auth", "401"]
                .contains(where: message.contains) { throw CodexQuotaError.loginRequired }
            throw CodexQuotaError.unavailable
        }
        guard let usage = payload.usage,
              usage.primary?.remainingPercent != nil || usage.secondary?.remainingPercent != nil else {
            throw CodexQuotaError.invalidResponse
        }
        return CodexQuotaSnapshot(
            primary: usage.primary, secondary: usage.secondary,
            plan: usage.identity?.loginMethod, updatedAt: receivedAt
        )
    }
}

/// A bounded subprocess reader dedicated to the optional quota helper. No shell, no unbounded pipe waits.
enum CodexQuotaProcess {
    static func run(executable: URL, arguments: [String], environment: [String: String],
                    timeout: TimeInterval = 25) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let stdout = output.fileHandleForReading.fileDescriptor
        let stderr = errors.fileHandleForReading.fileDescriptor
        _ = fcntl(stdout, F_SETFL, O_NONBLOCK)
        _ = fcntl(stderr, F_SETFL, O_NONBLOCK)
        defer {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }
        try Task.checkCancellation()
        do { try process.run() } catch { throw CodexQuotaError.missingHelper }
        defer {
            if process.isRunning { stop(process) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var totalRead = 0
        repeat {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexQuotaError.timedOut }
            for fd in [stdout, stderr] {
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    guard count > 0 else { break }
                    totalRead += count
                    guard totalRead <= 2_000_000 else { throw CodexQuotaError.invalidResponse }
                    if fd == stdout { data.append(contentsOf: buffer.prefix(count)) }
                }
            }
            if !process.isRunning {
                // Drain once more after exit; descendants retaining a pipe cannot block this reader.
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = Darwin.read(stdout, &buffer, buffer.count)
                    guard count > 0 else { break }
                    totalRead += count
                    guard totalRead <= 2_000_000 else { throw CodexQuotaError.invalidResponse }
                    data.append(contentsOf: buffer.prefix(count))
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
        guard !data.isEmpty else { throw CodexQuotaError.unavailable }
        return data
    }

    private static func stop(_ process: Process) {
        func children(of pid: pid_t) -> [pid_t] {
            var pids = [pid_t](repeating: 0, count: 256)
            let count = proc_listchildpids(pid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { return [] }
            return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }
        }
        var descendants: [pid_t] = []
        var pending = children(of: process.processIdentifier)
        while !pending.isEmpty, descendants.count < 256 {
            let pid = pending.removeLast()
            guard !descendants.contains(pid) else { continue }
            descendants.append(pid)
            pending.append(contentsOf: children(of: pid))
        }
        // Only signal the children still descended from this live helper, before killing their parent.
        for pid in descendants.reversed() { kill(pid, SIGKILL) }
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

struct CodexQuotaProvider: Sendable {
    let helperURL: URL
    let configURL: URL

    static var bundled: CodexQuotaProvider {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        return CodexQuotaProvider(
            helperURL: resources.appendingPathComponent("Helpers/CodexBar/CodexBarCLI"),
            configURL: resources.appendingPathComponent("CodexQuotaConfig.json")
        )
    }

    func fetch() async throws -> CodexQuotaSnapshot {
        let worker = Task.detached(priority: .utility) { () throws -> CodexQuotaSnapshot in
            guard FileManager.default.isExecutableFile(atPath: helperURL.path),
                  FileManager.default.fileExists(atPath: configURL.path) else {
                throw CodexQuotaError.missingHelper
            }
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let paths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                         "/Applications/ChatGPT.app/Contents/Resources",
                         "/Applications/Codex.app/Contents/Resources", "/usr/bin", "/bin"]
            environment["PATH"] = paths.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
            environment["CODEXBAR_CONFIG"] = configURL.path
            let data = try CodexQuotaProcess.run(
                executable: helperURL,
                arguments: ["usage", "--provider", "codex", "--source", "cli", "--format", "json", "--json-only"],
                environment: environment
            )
            return try CodexQuotaParser.parse(data)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

enum CodexQuotaConsumer: Hashable { case dashboard, menuBar }

struct CodexQuotaState {
    var snapshot: CodexQuotaSnapshot?
    var isRefreshing = false
    var error: CodexQuotaError?
}

@MainActor
final class CodexQuotaMonitor: ObservableObject {
    @Published private(set) var state = CodexQuotaState()
    private var consumers: Set<CodexQuotaConsumer> = []
    private var refreshTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastAttempt: TimeInterval?
    private let fetch: @Sendable () async throws -> CodexQuotaSnapshot
    private let interval: @Sendable () -> TimeInterval

    init(fetch: @escaping @Sendable () async throws -> CodexQuotaSnapshot = { try await CodexQuotaProvider.bundled.fetch() },
         interval: @escaping @Sendable () -> TimeInterval = {
             let info = ProcessInfo.processInfo
             return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical ? 300 : 60
         }) {
        self.fetch = fetch
        self.interval = interval
    }

    deinit { refreshTask?.cancel(); scheduledTask?.cancel() }

    func setActive(_ active: Bool, for consumer: CodexQuotaConsumer) {
        if active { consumers.insert(consumer) } else { consumers.remove(consumer) }
        if consumers.isEmpty {
            generation &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            scheduledTask?.cancel()
            scheduledTask = nil
            if state.isRefreshing {
                lastAttempt = nil
                var next = state
                next.isRefreshing = false
                state = next
            }
        } else {
            refresh()
        }
    }

    func refresh(force: Bool = false) {
        guard !consumers.isEmpty, !state.isRefreshing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = interval() - (now - (lastAttempt ?? -1_000_000))
        if !force, remaining > 0 { schedule(after: remaining); return }
        scheduledTask?.cancel()
        lastAttempt = now
        generation &+= 1
        let token = generation
        var next = state
        next.isRefreshing = true
        state = next
        let fetch = self.fetch
        refreshTask = Task { [weak self] in
            let result: Result<CodexQuotaSnapshot, Error>
            do { result = .success(try await fetch()) } catch { result = .failure(error) }
            guard !Task.isCancelled, let self, self.generation == token, !self.consumers.isEmpty else { return }
            var next = self.state
            next.isRefreshing = false
            switch result {
            case let .success(snapshot): next.snapshot = snapshot; next.error = nil
            case let .failure(error):
                next.error = error as? CodexQuotaError ?? .unavailable
                if next.error == .loginRequired { next.snapshot = nil }
            }
            self.state = next
            self.refreshTask = nil
            self.schedule(after: self.interval())
        }
    }

    private func schedule(after delay: TimeInterval) {
        scheduledTask?.cancel()
        scheduledTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.05, delay) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
