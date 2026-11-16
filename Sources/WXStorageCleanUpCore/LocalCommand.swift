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
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StorageError.invalid("无法准备本地连接输出通道。")
        }
        defer { try? pipe.fileHandleForReading.close() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        func drainAvailable() {
            var buffer = [UInt8](repeating: 0, count: 65536)
            // Bound each drain so noisy or inherited writers cannot starve
            // cancellation and deadline checks. Never wait for pipe EOF.
            for _ in 0..<16 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { output.append(Data(buffer.prefix(count))) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var stopRequested: TimeInterval?, cancelled = false
        while process.isRunning {
            drainAvailable()
            let now = ProcessInfo.processInfo.systemUptime
            if (!ignoreCancellation && Task.isCancelled) || now - started > timeout {
                if stopRequested == nil {
                    cancelled = !ignoreCancellation && Task.isCancelled
                    process.terminate(); stopRequested = now
                } else if now - stopRequested! > 15 {
                    // Only our exact child PID, never a process-name or system-wide kill.
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        drainAvailable()
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
