import XCTest
import Foundation
import Darwin
@testable import WXStorageCleanUpCore

final class AccountConnectionTests: XCTestCase {
    var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatAccountTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(temporary)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    func testAccountSwitchClearsSelectionAndInvalidAccountIsRejected() throws {
        var selection = AccountSelection()
        let accounts = [Account(id: "a", relativePath: "a"), Account(id: "b", relativePath: "b")]
        try selection.select("a", available: accounts)
        selection.setSelection(conversations: ["chat-a"], messages: ["message-a"])
        try selection.select("a", available: accounts)
        XCTAssertEqual(selection.messageIDs, ["message-a"])
        try selection.select("b", available: accounts)
        XCTAssertTrue(selection.conversationIDs.isEmpty)
        XCTAssertTrue(selection.messageIDs.isEmpty)
        XCTAssertThrowsError(try selection.select("c", available: accounts))
        XCTAssertEqual(selection.accountID, "b")
    }

    func testNamesAndMessagesStayScopedWhenAccountsHaveSameContactIDs() throws {
        let demo = try DemoFactory.createMultiple(parent: temporary)
        let inventory = try Scanner.scan(root: demo.root)
        XCTAssertEqual(inventory.accounts.count, 2)
        let indexes = try inventory.accounts.map {
            try IndexReader.load(snapshot: demo.snapshots[$0.id]!, account: $0, inventory: inventory)
        }
        let analysis = Analysis(inventory: inventory, indexes: indexes)
        let helpers = analysis.conversations.filter { $0.conversation.internalID == "filehelper" }
        XCTAssertEqual(helpers.count, 2)
        XCTAssertNotEqual(helpers[0].id, helpers[1].id)
        XCTAssertNotEqual(helpers[0].conversation.name, helpers[1].conversation.name)
        XCTAssertTrue(helpers[0].filePaths.isDisjoint(with: helpers[1].filePaths))
        for usage in helpers {
            let plan = try CleanupPlanner.plan(analysis: analysis, conversationIDs: [usage.id], allowedAccountID: usage.conversation.accountID)
            XCTAssertEqual(plan.accountIDs, [usage.conversation.accountID])
            XCTAssertTrue(plan.candidates.allSatisfy { $0.relativePath.contains("/" + usage.conversation.accountID + "/") })
        }
        XCTAssertThrowsError(try CleanupPlanner.plan(analysis: analysis,
            conversationIDs: Set(helpers.map(\.id)), allowedAccountID: helpers[0].conversation.accountID))
    }

    func testConnectionCacheAndForgetAreIsolatedByRootAndAccount() throws {
        let rootA = temporary.appendingPathComponent("root-a"), rootB = temporary.appendingPathComponent("root-b")
        try FileSafety.privateDirectory(rootA); try FileSafety.privateDirectory(rootB)
        let store = AccountConnectionStore(directory: temporary.appendingPathComponent("connections"))
        try store.save(accountID: "a", root: rootA, snapshot: temporary.appendingPathComponent("snapshot-a"))
        try store.save(accountID: "b", root: rootA, snapshot: temporary.appendingPathComponent("snapshot-b"))
        XCTAssertNotEqual(store.keyFile(root: rootA, accountID: "a"), store.keyFile(root: rootA, accountID: "b"))
        XCTAssertNotEqual(store.keyFile(root: rootA, accountID: "a"), store.keyFile(root: rootB, accountID: "a"))
        XCTAssertNil(store.saved(accountID: "a", root: rootB))
        XCTAssertNotNil(store.saved(accountID: "a", root: rootA))
        try store.forget(accountID: "a", root: rootA)
        XCTAssertNil(store.saved(accountID: "a", root: rootA))
        XCTAssertNotNil(store.saved(accountID: "b", root: rootA))
    }

    func testOlderOperationRecordsDecodeWithoutAccountField() throws {
        let record: [String: Any] = ["id": UUID().uuidString, "root": temporary.path, "createdAt": 0,
            "logicalBytes": 0, "state": "completed", "items": [], "notes": []]
        let decoded = try JSONDecoder().decode(CleanupRecord.self, from: JSONSerialization.data(withJSONObject: record))
        XCTAssertNil(decoded.accountIDs)
    }

    func testCommandEventsContainMetadataAndCancellationStopsOwnedTask() async throws {
        let result = try LocalCommand.run("/usr/bin/python3", ["-c", "print('{\"event\":\"cache\",\"verified\":1,\"total\":2}')"])
        XCTAssertEqual(result.events.first?.verified, 1)
        let task = Task.detached {
            try LocalCommand.run("/usr/bin/python3", ["-c", "import time; time.sleep(30)"], timeout: 40)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {}
    }

    func testCommandReturnsWhenDescendantKeepsOutputPipeOpen() throws {
        let started = Date()
        let script = "import subprocess,sys,json; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(5)']); print(json.dumps({'event':'launched','pid':child.pid}), flush=True)"
        let result = try LocalCommand.run("/usr/bin/python3", ["-c", script], timeout: 2)
        if let pid = result.events.first?.pid { _ = Darwin.kill(pid, SIGTERM) }
        XCTAssertEqual(result.status, 0)
        XCTAssertNotNil(result.events.first?.pid)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testSQLCipherChildTimeoutReturnsAnError() throws {
        let executable = temporary.appendingPathComponent("owned-sqlcipher-fixture")
        try Data("#!/usr/bin/python3\nimport time\ntime.sleep(30)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        XCTAssertThrowsError(try SnapshotService.runSQLCipher(executable: executable,
            database: temporary.appendingPathComponent("unused.db"), script: ".quit\n", timeout: 0.1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("超出时限"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testSQLCipherGrowingOutputExtendsIdleDeadline() throws {
        // Launch the system shell directly: executing a new unsigned script can
        // incur macOS launch assessment delays unrelated to output inactivity.
        let fixture = temporary.appendingPathComponent("growing-output.sh")
        let source = "#!/bin/sh\nIFS= read -r output\n: > \"$output\"\ni=0\nwhile [ \"$i\" -lt 80 ]; do\n printf '0123456789' >> \"$output\"\n /bin/sleep 0.05\n i=$((i+1))\ndone\n"
        try Data(source.utf8).write(to: fixture)
        let output = temporary.appendingPathComponent("fixture-output.db")
        try SnapshotService.runSQLCipher(executable: URL(fileURLWithPath: "/bin/sh"), database: fixture,
            script: output.path + "\n", timeout: 3, outputDatabase: output)
        XCTAssertEqual(try Data(contentsOf: output).count, 80 * 10)
    }

    func testTemporaryLaunchPreservesContainerHomeForAllScanEntryPoints() throws {
        let home = temporary.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data")
        for relative in ["Documents/xwechat_files/a/db_storage", "Documents/xwechat_files/b/db_storage"] {
            XCTAssertEqual(AutomaticConnection.dataHome(databaseRoot: home.appendingPathComponent(relative))?.path, home.path)
        }
        let external = temporary.appendingPathComponent("external/xwechat_files/a/db_storage")
        let fallback = temporary.appendingPathComponent("original-container")
        XCTAssertNil(AutomaticConnection.dataHome(databaseRoot: external, fallback: fallback))
        try FileSafety.privateDirectory(fallback)
        XCTAssertEqual(AutomaticConnection.dataHome(databaseRoot: external, fallback: fallback), fallback)
    }

    func testCaptureFeedbackExplainsWaitingAndPartialOrZeroKeyFailure() throws {
        func event(_ json: String) throws -> CaptureEvent { try JSONDecoder().decode(CaptureEvent.self, from: Data(json.utf8)) }
        let waiting = try event(#"{"event":"waiting","verified":1,"total":2,"pending":["message/message_0.db"],"elapsed":30,"remaining":210}"#)
        let phase = CaptureFeedback.phase(waiting)
        XCTAssertTrue(phase.contains("30 秒"))
        XCTAssertTrue(phase.contains("210 秒"))
        XCTAssertTrue(phase.contains("message/message_0.db"))
        let partial = LocalCommandResult(status: 3, output: Data(), events: [waiting,
            try event(#"{"event":"incomplete","code":"capture_timeout","verified":1,"total":2,"pending":["message/message_0.db"]}"#)])
        XCTAssertTrue(CaptureFeedback.failure(partial).contains("已验证的密钥保存在本机"))
        XCTAssertTrue(CaptureFeedback.failure(partial).contains("message/message_0.db"))
        let zero = LocalCommandResult(status: 3, output: Data(), events: [
            try event(#"{"event":"incomplete","code":"child_exited","verified":0,"total":2}"#)])
        XCTAssertTrue(CaptureFeedback.failure(zero).contains("取齐密钥前退出"))
        XCTAssertTrue(CaptureFeedback.failure(zero).contains("版本或调试环境不兼容"))
        let denied = LocalCommandResult(status: 2, output: Data(), events: [
            try event(#"{"event":"error","code":"debug_launch_denied"}"#)])
        XCTAssertTrue(CaptureFeedback.failure(denied).contains("开发者工具权限"))
        let resumed = LocalCommandResult(status: 2, output: Data(), events: [
            try event(#"{"event":"error","code":"child_resume_failed","state":5,"errorType":1,"errorCode":7}"#)])
        XCTAssertTrue(CaptureFeedback.failure(resumed).contains("Command Line Tools"))
        XCTAssertFalse(CaptureFeedback.failure(resumed).contains("开发者工具权限"))
    }

    func testConnectionDiagnosticIsPrivateScopedAndExcludesRawOutput() throws {
        let store = AccountConnectionStore(directory: temporary.appendingPathComponent("connections"))
        let metadata = try JSONDecoder().decode(CaptureEvent.self, from: Data(
            #"{"event":"error","code":"child_resume_failed","state":5,"errorCode":7,"resumeKind":"other"}"#.utf8))
        let debugger = try JSONDecoder().decode(CaptureEvent.self, from: Data(
            #"{"event":"debugger","lldbVersion":"lldb-1403"}"#.utf8))
        let output = LocalCommandResult(status: 2, output: Data("private-key-and-chat-text".utf8), events: [debugger, metadata])
        try store.saveDiagnostic(output, root: temporary, accountID: "a", application: temporary.appendingPathComponent("fixture.app"))
        let text = try store.diagnosticText(root: temporary, accountID: "a")
        XCTAssertTrue(text.contains("lldb-1403"))
        XCTAssertTrue(text.contains("child_resume_failed"))
        XCTAssertFalse(text.contains("private-key-and-chat-text"))
        XCTAssertFalse(text.contains(temporary.path))
        XCTAssertThrowsError(try store.diagnosticText(root: temporary, accountID: "b"))
        let file = store.accountDirectory(root: temporary, accountID: "a").appendingPathComponent("last-connection-diagnostic.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
