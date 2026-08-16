import Foundation
import Darwin

struct CommandResult {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
    let timedOut: Bool

    var outputString: String {
        String(data: standardOutput, encoding: .utf8) ?? ""
    }

    var errorString: String {
        String(data: standardError, encoding: .utf8) ?? ""
    }
}

private final class CommandDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum CommandRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> CommandResult? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let environment {
            process.environment = environment
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return nil
        }

        let outputBuffer = CommandDataBuffer()
        let errorBuffer = CommandDataBuffer()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBuffer.store(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBuffer.store(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        var timedOut = false
        if finished.wait(timeout: .now() + max(0.1, timeout)) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        process.terminationHandler = nil
        readers.wait()

        return CommandResult(
            standardOutput: outputBuffer.data,
            standardError: errorBuffer.data,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }
}
