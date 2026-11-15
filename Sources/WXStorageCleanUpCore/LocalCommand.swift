import Foundation
import Darwin

struct CaptureEvent: Codable, Sendable {
    let event: String
    let verified: Int?
    let total: Int?
    let complete: Bool?
    let pid: Int32?
    let code: String?
    let pending: [String]?
    let elapsed: Int?
    let remaining: Int?
    let observations: Int?
    let lldbVersion: String?
    let state: Int?
    let stopID: Int?
    let stopReasons: [Int]?
    let errorType: Int?
    let errorCode: Int?
    let resumeKind: String?
    let exitStatus: Int?
    let breakpointLocations: Int?
    let targetArchitecture: String?
}

struct LocalCommandResult: Sendable {
    let status: Int32
    let output: Data
    let events: [CaptureEvent]
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data(), pending = Data(), decoded = [CaptureEvent]()
    let callback: (@Sendable (CaptureEvent) -> Void)?
    init(_ callback: (@Sendable (CaptureEvent) -> Void)?) { self.callback = callback }
    func append(_ chunk: Data) {
        lock.lock()
        if bytes.count < 1024 * 1024 { bytes.append(chunk.prefix(1024 * 1024 - bytes.count)) }
        pending.append(chunk)
        var events = [CaptureEvent]()
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            if line.count < 16_384, let event = try? JSONDecoder().decode(CaptureEvent.self, from: Data(line)) {
                if decoded.count < 1024 { decoded.append(event) }; events.append(event)
            }
            pending.removeSubrange(...newline)
        }
        if pending.count > 32_768 { pending = Data() }
        lock.unlock()
        for event in events { callback?(event) }
    }
    func result(_ status: Int32) -> LocalCommandResult {
        lock.lock(); defer { lock.unlock() }
        return LocalCommandResult(status: status, output: bytes, events: decoded)
    }
}

enum LocalCommand {
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 60, ignoreCancellation: Bool = false,
                    event: (@Sendable (CaptureEvent) -> Void)? = nil) throws -> LocalCommandResult {
        let process = Process(), pipe = Pipe(), output = CommandOutput(event)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardOutput = pipe
        let drained = DispatchGroup()
        try process.run()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }; output.append(data)
            }
            drained.leave()
        }
        let started = Date()
        var stopRequested: Date?, cancelled = false
        while process.isRunning {
            if (!ignoreCancellation && Task.isCancelled) || Date().timeIntervalSince(started) > timeout {
                if stopRequested == nil {
                    cancelled = !ignoreCancellation && Task.isCancelled
                    process.terminate(); stopRequested = Date()
                } else if Date().timeIntervalSince(stopRequested!) > 15 {
                    // Only our exact child PID, never a process-name or system-wide kill.
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit(); drained.wait()
        if cancelled { throw CancellationError() }
        if stopRequested != nil { throw StorageError.invalid("本地连接步骤超时，已停止本工具启动的任务。") }
        return output.result(process.terminationStatus)
    }

    static func require(_ executable: String, _ arguments: [String], timeout: TimeInterval = 60,
                        ignoreCancellation: Bool = false) throws -> Data {
        let result = try run(executable, arguments, timeout: timeout, ignoreCancellation: ignoreCancellation)
        guard result.status == 0 else { throw StorageError.invalid("本地连接步骤执行失败：\(URL(fileURLWithPath: executable).lastPathComponent)。") }
        return result.output
    }
}
