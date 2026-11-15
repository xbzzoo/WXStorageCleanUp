import XCTest
import Foundation
import AppKit
import Darwin
@testable import WXStorageCleanUpCore

final class TemporaryApplicationTests: XCTestCase {
    private let application = URL(fileURLWithPath: "/fixture/session/WeChat.app")

    private func process(_ pid: Int32, _ path: String, birth: UInt64 = 1, stopped: Bool = false) -> TemporaryProcess {
        .init(id: .init(pid: pid, executable: path, startedSeconds: birth, startedMicroseconds: 0), stopped: stopped)
    }

    func testUnregisteredMainAndHelperExitWithoutSignallingOriginalOrSibling() {
        let main = process(10, application.path + "/Contents/MacOS/WeChat")
        let helper = process(11, application.path + "/Contents/Frameworks/Helper")
        let original = process(12, "/Applications/WeChat.app/Contents/MacOS/WeChat")
        let sibling = process(13, "/fixture/session/WeChat.app-other/Contents/MacOS/WeChat")
        var processes = [main, helper, original, sibling]
        var elapsed: TimeInterval = 0
        var signals = [Int32](), quits = [Int32]()
        let closer = TemporaryApplicationCloser(snapshot: { processes }, current: { pid in processes.first { $0.id.pid == pid } },
            requestQuit: { quits = $0.map(\.id.pid) }, sendSignal: { pid, signal in
                XCTAssertEqual(signal, SIGTERM)
                signals.append(pid); processes.removeAll { $0.id.pid == pid }; return 0
            }, now: { elapsed }, pause: { elapsed += $0 })
        XCTAssertEqual(closer.close(application, grace: 0.2, timeout: 1), .closed)
        XCTAssertEqual(Set(quits), [10, 11])
        XCTAssertEqual(Set(signals), [10, 11])
        XCTAssertEqual(processes.map(\.id.pid), [12, 13])
    }

    func testReusedPIDIsRecheckedBeforeAnySignal() {
        let old = process(10, application.path + "/Contents/MacOS/WeChat")
        let replacement = process(10, old.id.executable, birth: 2)
        var elapsed: TimeInterval = 0, signals = 0
        let closer = TemporaryApplicationCloser(snapshot: { [old] }, current: { _ in replacement }, requestQuit: { _ in },
            sendSignal: { _, _ in signals += 1; return 0 }, now: { elapsed }, pause: { elapsed += $0 })
        XCTAssertEqual(closer.close(application, grace: 0, timeout: 0.3), .stillRunning(1))
        XCTAssertEqual(signals, 0)
    }

    func testStoppedChildResumesOnlyAfterTerminationWasRequested() {
        let child = process(10, application.path + "/Contents/MacOS/WeChat", stopped: true)
        var processes = [child], signals = [Int32]()
        var elapsed: TimeInterval = 0
        let closer = TemporaryApplicationCloser(snapshot: { processes }, current: { _ in processes.first }, requestQuit: { _ in },
            sendSignal: { pid, signal in
                XCTAssertEqual(pid, child.id.pid)
                signals.append(signal)
                if signal == SIGCONT { processes = [] }
                return 0
            }, now: { elapsed }, pause: { elapsed += $0 })
        XCTAssertEqual(closer.close(application, grace: 0, timeout: 1), .closed)
        XCTAssertEqual(signals, [SIGTERM, SIGCONT])
    }

    func testRefusedTerminationStaysBoundedAndInspectionFailureIsNotSuccess() {
        let child = process(10, application.path + "/Contents/MacOS/WeChat")
        var elapsed: TimeInterval = 0, signals = [Int32]()
        var closer = TemporaryApplicationCloser(snapshot: { [child] }, current: { _ in child }, requestQuit: { _ in },
            sendSignal: { _, signal in signals.append(signal); return 0 }, now: { elapsed }, pause: { elapsed += $0 })
        XCTAssertEqual(closer.close(application, grace: 0, timeout: 0.3), .stillRunning(1))
        XCTAssertEqual(signals, [SIGTERM])
        closer.snapshot = { nil }
        XCTAssertEqual(closer.close(application), .unableToInspect)
    }

    func testExitFailurePreservesCaptureResultAndDistinguishesUnknownState() {
        let original = StorageError.invalid("已验证 2/3 个加密索引。尚缺 message/message_0.db。")
        let message = TemporaryApplicationExit.stillRunning(1).failureMessage(application: application,
            captureError: original, verified: 2, total: 3)
        XCTAssertTrue(message.contains(original.localizedDescription))
        XCTAssertTrue(message.contains("1 个临时微信进程"))
        XCTAssertTrue(message.contains(application.path))
        let success = TemporaryApplicationExit.unableToInspect.failureMessage(application: application,
            captureError: nil, verified: 3, total: 3)
        XCTAssertTrue(success.contains("取钥步骤已完成"))
        XCTAssertTrue(success.contains("3/3"))
        XCTAssertTrue(success.contains("无法确认"))
    }

    func testActualUnregisteredStoppedChildExitsAndUnrelatedProcessSurvives() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryAppExit-" + UUID().uuidString)
        try FileSafety.privateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("WeChat.app")
        let executable = app.appendingPathComponent("Contents/MacOS/fixture")
        try FileSafety.privateDirectory(executable.deletingLastPathComponent())
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let child = Process(), unrelated = Process()
        child.executableURL = executable; child.arguments = ["30"]
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGCONT); child.terminate(); child.waitUntilExit() }
        }
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        XCTAssertFalse(NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == child.processIdentifier })
        XCTAssertEqual(Darwin.kill(child.processIdentifier, SIGSTOP), 0)
        let deadline = Date().addingTimeInterval(2)
        while TemporaryApplicationCloser.inspect(child.processIdentifier)?.stopped != true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(try XCTUnwrap(TemporaryApplicationCloser.inspect(child.processIdentifier)).stopped)
        let result = TemporaryApplicationCloser().close(app, grace: 0.1, timeout: 3)
        XCTAssertEqual(result, .closed)
        if result == .closed { child.waitUntilExit() }
        XCTAssertTrue(unrelated.isRunning)
    }
}
