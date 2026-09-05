import Foundation

@main
struct CodexQuotaTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor static func waitUntil(_ message: String,
                                     condition: @MainActor () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await condition()) {
            expect(ProcessInfo.processInfo.systemUptime < deadline, message)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    static let valid = Data(#"[{"provider":"codex","usage":{"primary":{"usedPercent":28,"windowMinutes":300,"resetsAt":"2026-09-05T12:00:00.000Z"},"secondary":{"usedPercent":59,"windowMinutes":10080,"resetsAt":"2026-09-08T12:00:00Z"},"identity":{"loginMethod":"Plus"}}}]"#.utf8)

    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--live" {
            let provider = CodexQuotaProvider(helperURL: URL(fileURLWithPath: CommandLine.arguments[2]),
                                              configURL: URL(fileURLWithPath: CommandLine.arguments[3]))
            do {
                let snapshot = try await provider.fetch()
                print("LIVE quota fetch passed; primary remaining=\(snapshot.primary?.remainingPercent ?? -1), secondary remaining=\(snapshot.secondary?.remainingPercent ?? -1); no identity or credentials logged")
            } catch {
                print("LIVE quota fetch failed: \(error.localizedDescription)")
                exit(1)
            }
            return
        }
        let snapshot = try CodexQuotaParser.parse(valid)
        expect(snapshot.primary?.remainingPercent == 72, "used and remaining must not be swapped")
        expect(snapshot.secondary?.remainingPercent == 41, "weekly conversion")
        expect(snapshot.primary?.resetsAt != nil && snapshot.secondary?.resetsAt != nil, "both ISO date formats")

        let zero = Data(#"[{"provider":"codex","usage":{"primary":{"usedPercent":100},"secondary":null}}]"#.utf8)
        expect(tryRemaining(zero) == 0, "exhaustion must be a real zero")
        let missing = Data(#"[{"provider":"codex","usage":{"primary":null,"secondary":{"usedPercent":12}}}]"#.utf8)
        let missingSnapshot = try CodexQuotaParser.parse(missing)
        expect(missingSnapshot.primary == nil, "missing primary must remain unavailable")
        for json in [#"[{"provider":"codex","usage":{"primary":{"usedPercent":0,"isSyntheticPlaceholder":true}}}]"#,
                     #"[{"provider":"codex","usage":{}}]"#, #"{}"#] {
            do { _ = try CodexQuotaParser.parse(Data(json.utf8)); fatalError("invalid quota accepted") }
            catch { expect(error as? CodexQuotaError == .invalidResponse, "missing quota classification") }
        }
        do {
            _ = try CodexQuotaParser.parse(Data(#"[{"provider":"codex","error":{"message":"401 credentials expired secret-value"}}]"#.utf8))
            fatalError("auth error accepted")
        } catch {
            expect(error as? CodexQuotaError == .loginRequired, "auth classification")
            expect(!error.localizedDescription.contains("secret-value"), "raw errors must not leak")
        }
        print("Parser: remaining, exhaustion, unavailable, placeholder, dates, auth redaction passed")

        let source = ControlledSource(snapshot: snapshot)
        let model = CodexQuotaMonitor(fetch: { try await source.fetch() }, interval: { 60 })
        try await Task.sleep(nanoseconds: 20_000_000)
        let initialCount = await source.count
        expect(initialCount == 0, "no work before activation")
        model.setActive(true, for: .dashboard)
        model.setActive(true, for: .menuBar)
        try await waitUntil("shared result completes") { model.state.snapshot == snapshot && !model.state.isRefreshing }
        expect(model.state.snapshot == snapshot, "shared result")
        let firstCount = await source.count
        expect(firstCount == 1, "two consumers must share one request")
        model.setActive(false, for: .dashboard)
        model.refresh()
        let throttledCount = await source.count
        expect(throttledCount == 1, "cached read must not fetch again")
        model.setActive(false, for: .menuBar)
        model.refresh(force: true)
        let hiddenCount = await source.count
        expect(hiddenCount == 1, "hidden model cannot fetch")
        print("Lifecycle: shared fetch, cache throttle, hidden refresh suppression passed")

        model.setActive(true, for: .dashboard)
        await source.fail(with: .unavailable)
        model.refresh(force: true)
        try await waitUntil("transient failure completes") { model.state.error == .unavailable && !model.state.isRefreshing }
        expect(model.state.snapshot == snapshot && model.state.error == .unavailable, "transient error retains labeled cache")
        await source.fail(with: .loginRequired)
        model.refresh(force: true)
        try await waitUntil("auth failure completes") { model.state.error == .loginRequired && !model.state.isRefreshing }
        expect(model.state.snapshot == nil && model.state.error == .loginRequired, "auth failure clears cached account quota")
        model.setActive(false, for: .dashboard)

        let tickingSource = ControlledSource(snapshot: snapshot)
        let ticking = CodexQuotaMonitor(fetch: { try await tickingSource.fetch() }, interval: { 0.06 })
        ticking.setActive(true, for: .dashboard)
        // Wait for actual completed polls, not a wall-clock assumption about CI scheduling.
        try await waitUntil("automatic polling completes twice") {
            let count = await tickingSource.count
            return count >= 2 && !ticking.state.isRefreshing
        }
        ticking.setActive(false, for: .dashboard)
        let stoppedCount = await tickingSource.count
        try await Task.sleep(nanoseconds: 200_000_000)
        let laterCount = await tickingSource.count
        expect(stoppedCount >= 2 && stoppedCount == laterCount, "automatic polling stops when hidden")
        print("Failure cache policy and automatic timer shutdown passed")

        let delayed = CodexQuotaMonitor(fetch: {
            // Simulates a provider which ignores cancellation and returns a late response.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return snapshot
        })
        delayed.setActive(true, for: .menuBar)
        delayed.setActive(false, for: .menuBar)
        try await Task.sleep(nanoseconds: 120_000_000)
        expect(delayed.state.snapshot == nil && !delayed.state.isRefreshing, "late response after hiding discarded")

        let started = ProcessInfo.processInfo.systemUptime
        let timedOut = await Task.detached { () -> Bool in
            do {
                _ = try CodexQuotaProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; /bin/sleep 30 & wait"], environment: [:], timeout: 0.2)
                return false
            } catch { return error as? CodexQuotaError == .timedOut }
        }.value
        expect(timedOut && ProcessInfo.processInfo.systemUptime - started < 2, "bounded termination")
        print("Cancellation and subprocess timeout passed")
    }

    static func tryRemaining(_ data: Data) -> Double? { try? CodexQuotaParser.parse(data).primary?.remainingPercent }
}

actor ControlledSource {
    var count = 0
    var error: CodexQuotaError?
    let snapshot: CodexQuotaSnapshot
    init(snapshot: CodexQuotaSnapshot) { self.snapshot = snapshot }
    func fetch() async throws -> CodexQuotaSnapshot {
        count += 1
        try await Task.sleep(nanoseconds: 10_000_000)
        if let error { throw error }
        return snapshot
    }
    func fail(with error: CodexQuotaError) { self.error = error }
}
