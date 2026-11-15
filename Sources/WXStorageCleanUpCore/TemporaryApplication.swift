import Foundation
import AppKit
import Darwin

struct TemporaryProcessID: Hashable {
    let pid: Int32
    let executable: String
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
}

struct TemporaryProcess {
    let id: TemporaryProcessID
    let stopped: Bool
}

enum TemporaryApplicationExit: Equatable {
    case closed
    case stillRunning(Int)
    case unableToInspect

    func failureMessage(application: URL, captureError: Error?, verified: Int, total: Int) -> String {
        let result: String
        if let captureError {
            result = captureError is CancellationError ? "连接已取消，已验证的密钥会保留。" : captureError.localizedDescription
        } else {
            result = "取钥步骤已完成，已验证 \(verified)/\(total) 个加密索引；退出临时微信后可再次连接并复用有效密钥。"
        }
        let cleanup: String
        switch self {
        case .unableToInspect: cleanup = "无法确认临时微信的进程状态，已保留临时目录。"
        case .stillRunning(let count): cleanup = "仍有 \(count) 个临时微信进程未退出，已保留临时目录。"
        case .closed: return result
        }
        return result + "\n\n" + cleanup + "请对该临时窗口按 ⌘Q；若没有窗口，请在活动监视器中核对进程的路径后退出。原版微信未被重签名。\n临时位置：" + application.path
    }
}

/// Normal app quit first, then SIGTERM for verified processes inside this exact
/// temporary bundle. No bundle-ID/name-wide termination, and no SIGKILL.
struct TemporaryApplicationCloser {
    var snapshot: () -> [TemporaryProcess]? = systemSnapshot
    var current: (Int32) -> TemporaryProcess? = inspect
    var requestQuit: ([TemporaryProcess]) -> Void = { processes in
        for process in processes {
            guard inspect(process.id.pid)?.id == process.id,
                  let app = NSRunningApplication(processIdentifier: process.id.pid),
                  app.executableURL?.resolvingSymlinksInPath().path == process.id.executable else { continue }
            _ = app.terminate()
        }
    }
    var sendSignal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func close(_ application: URL, grace: TimeInterval = 3, timeout: TimeInterval = 15) -> TemporaryApplicationExit {
        let prefix = application.resolvingSymlinksInPath().path + "/Contents/"
        func remaining() -> [TemporaryProcess]? {
            snapshot()?.filter { $0.id.executable.hasPrefix(prefix) }
        }
        guard let initial = remaining() else { return .unableToInspect }
        if initial.isEmpty { return .closed }
        requestQuit(initial)
        let started = now()
        var signalled = Set<TemporaryProcessID>()
        while true {
            guard let processes = remaining() else { return .unableToInspect }
            if processes.isEmpty { return .closed }
            let elapsed = now() - started
            if elapsed >= timeout { return .stillRunning(processes.count) }
            if elapsed >= grace {
                for process in processes where !signalled.contains(process.id) {
                    // Recheck executable, UID and process birth time immediately
                    // before each signal; a recycled PID must not become a target.
                    guard current(process.id.pid)?.id == process.id else { continue }
                    if sendSignal(process.id.pid, SIGTERM) == 0 {
                        signalled.insert(process.id)
                        // A debugger-stopped child cannot handle pending SIGTERM
                        // until it resumes. Resume only that same verified process.
                        if let latest = current(process.id.pid), latest.id == process.id, latest.stopped {
                            _ = sendSignal(process.id.pid, SIGCONT)
                        }
                    }
                }
            }
            pause(0.1)
        }
    }

    static func inspect(_ pid: Int32) -> TemporaryProcess? {
        guard pid > 0 else { return nil }
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        var before = proc_bsdinfo(), after = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &before, size) == size,
              before.pbi_uid == getuid() else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &after, size) == size,
              after.pbi_uid == before.pbi_uid,
              after.pbi_start_tvsec == before.pbi_start_tvsec,
              after.pbi_start_tvusec == before.pbi_start_tvusec else { return nil }
        return TemporaryProcess(id: .init(pid: pid,
            executable: URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path,
            startedSeconds: after.pbi_start_tvsec, startedMicroseconds: after.pbi_start_tvusec),
            stopped: after.pbi_status == SSTOP)
    }

    static func systemSnapshot() -> [TemporaryProcess]? {
        // The process list can grow between sizing and reading. Retry rather
        // than reporting success from a potentially truncated list.
        for _ in 0..<3 {
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return nil }
            var pids = [Int32](repeating: 0, count: Int(count) + 256)
            let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
            guard found > 0 else { return nil }
            if found >= pids.count { continue }
            return pids.prefix(Int(found)).compactMap { inspect($0) }
        }
        return nil
    }
}
