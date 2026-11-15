import XCTest
import Foundation
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
}
