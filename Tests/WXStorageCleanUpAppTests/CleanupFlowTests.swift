import XCTest
@testable import WXStorageCleanUpApp
import WXStorageCleanUpCore

@MainActor final class CleanupFlowTests: XCTestCase {
    private func waitUntilIdle(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.errorMessage)
    }
    func testLoadingBlocksPanelAndClipboardActions() {
        let model = AppModel()
        model.busy = true
        model.pickRoot()
        model.importSnapshot()
        model.importKeys()
        model.exportAnalysis()
        model.openConnectionGuide()
        model.copyConnectionDiagnostics()
        XCTAssertTrue(model.busy)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.plan)
    }

    func testCleanThenSelectAnotherChatAndCleanAgain() async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CleanupFlowTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let demo = try DemoFactory.create(parent: temporary, includeUnassigned: true)
        let service = CleanupService(journalDirectory: temporary.appendingPathComponent("journal"))
        let model = AppModel(cleanup: service)
        model.scan(demo.root, demo: true)
        try await waitUntilIdle(model)
        let inventory = try XCTUnwrap(model.inventory)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        model.indexes = [index.accountID: index]
        model.analysis = Analysis(inventory: inventory, indexes: [index])
        model.page = .chats
        let chats = ["wxid_demo_mia", "filehelper"]
        let trash = temporary.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for internalID in chats {
            model.selectedConversation = try XCTUnwrap(model.analysis?.conversations.first { $0.conversation.internalID == internalID }?.id)
            XCTAssertTrue(model.canCleanCurrentConversation)
            let scannedAt = model.inventory?.scannedAt
            model.previewCurrentConversation()
            try await waitUntilIdle(model)
            XCTAssertFalse(try XCTUnwrap(model.plan).candidates.isEmpty)
            model.executePlan(trash: { source in
                let target = trash.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: source, to: target); return target
            })
            try await waitUntilIdle(model)
            XCTAssertEqual(model.inventory?.scannedAt, scannedAt)
            XCTAssertEqual(model.page, .chats)
            XCTAssertNotNil(model.currentConversation)
            XCTAssertTrue(model.checkedMessages.isEmpty)
            XCTAssertTrue(model.checkedConversations.isEmpty)
            XCTAssertNil(model.plan)
            XCTAssertEqual(model.cleanupCompletion?.trashedCount, model.records.first?.trashedCount)
            XCTAssertTrue(model.cleanupCompletionMessage.contains("清空废纸篓"))
            model.cleanupCompletion = nil
        }
        XCTAssertEqual(model.records.count, 2)
        model.selectedConversation = model.analysis?.conversations.first { $0.conversation.internalID == "wxid_demo_mia" }?.id
        XCTAssertNil(model.currentConversation)
        XCTAssertFalse(model.canCleanCurrentConversation)
    }
    func testUnassignedCleanupRefreshAndRestoreKeepsCurrentPage() async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("UnassignedFlowTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let demo = try DemoFactory.create(parent: temporary, includeUnassigned: true)
        let service = CleanupService(journalDirectory: temporary.appendingPathComponent("journal"))
        let model = AppModel(cleanup: service)
        model.scan(demo.root, demo: true)
        try await waitUntilIdle(model)
        let inventory = try XCTUnwrap(model.inventory)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        model.indexes = [index.accountID: index]
        model.analysis = Analysis(inventory: inventory, indexes: [index])
        model.page = .unassigned
        let initialCount = model.accountUnassigned.count
        let file = try XCTUnwrap(model.visibleUnassigned.first { $0.identity.links > 1 })
        model.checkedUnassigned = [file.id]
        model.previewUnassigned()
        try await waitUntilIdle(model)
        let trash = temporary.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        model.executePlan(trash: { source in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target); return target
        })
        try await waitUntilIdle(model)
        XCTAssertEqual(model.page, .unassigned)
        XCTAssertTrue(model.checkedUnassigned.isEmpty)
        XCTAssertEqual(model.accountUnassigned.count, initialCount - 1)
        XCTAssertEqual(model.cleanupCompletion?.trashedCount, 1)
        XCTAssertTrue(model.cleanupCompletionMessage.contains("清空废纸篓"))
        XCTAssertTrue(model.cleanupCompletionMessage.contains("其他硬链接"))
        model.cleanupCompletion = nil
        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(try service.restore(record, processIsRunning: { false }).restoredCount, 1)
        model.refresh()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.page, .unassigned)
        XCTAssertEqual(model.accountUnassigned.count, initialCount)
    }
    func testUnassignedFiltersSelectionAndAccountSwitch() async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("UnassignedModelTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let demo = try DemoFactory.createMultiple(parent: temporary, includeUnassigned: true)
        let inventory = try Scanner.scan(root: demo.root)
        let indexes = try inventory.accounts.map { try IndexReader.load(snapshot: demo.snapshots[$0.id]!, account: $0, inventory: inventory) }
        let model = AppModel(cleanup: CleanupService(journalDirectory: temporary.appendingPathComponent("journal")))
        model.isDemo = true; model.inventory = inventory
        model.analysis = Analysis(inventory: inventory, indexes: indexes)
        model.selectedAccount = inventory.accounts[0].id
        model.unassignedType = "视频"
        XCTAssertFalse(model.visibleUnassigned.isEmpty)
        XCTAssertTrue(model.visibleUnassigned.allSatisfy { $0.attachmentKind == .video && $0.accountID == model.selectedAccount })
        let file = try XCTUnwrap(model.visibleUnassigned.first { $0.identity.links == 1 })
        model.checkedUnassigned = [file.id]
        model.previewUnassigned()
        try await waitUntilIdle(model)
        XCTAssertEqual(model.plan?.scope, .unassignedAttachments)
        model.selectedAccount = inventory.accounts[1].id
        XCTAssertTrue(model.checkedUnassigned.isEmpty)
        XCTAssertEqual(model.unassignedType, "全部")
        XCTAssertNil(model.plan)
        XCTAssertTrue(model.visibleUnassigned.allSatisfy { $0.accountID == inventory.accounts[1].id })
        model.unassignedSearch = "no-match"
        XCTAssertTrue(model.visibleUnassigned.isEmpty)
    }
}
