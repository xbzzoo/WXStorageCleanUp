import XCTest
@testable import WXStorageCleanUpCore

final class UnassignedAttachmentTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("UnassignedAttachmentTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(temporary)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }

    private func environment() throws -> (Inventory, Analysis) {
        let demo = try DemoFactory.createMultiple(parent: temporary, includeUnassigned: true)
        let inventory = try Scanner.scan(root: demo.root)
        let indexes = try inventory.accounts.map {
            try IndexReader.load(snapshot: demo.snapshots[$0.id]!, account: $0, inventory: inventory)
        }
        return (inventory, Analysis(inventory: inventory, indexes: indexes))
    }
    func testUnassignedListExcludesAssignedPathsAndNonAttachments() throws {
        let (inventory, analysis) = try environment()
        let assigned = Set(analysis.conversations.flatMap(\.filePaths))
        XCTAssertFalse(analysis.unassignedAttachments.isEmpty)
        XCTAssertTrue(analysis.unassignedAttachments.allSatisfy { $0.category == .attachment && !assigned.contains($0.id) })
        XCTAssertEqual(Set(analysis.unassignedAttachments.map(\.id)).union(assigned),
            Set(inventory.files.filter { $0.category == .attachment }.map(\.id)))
        XCTAssertTrue(analysis.unassignedAttachments.contains { $0.attachmentKind == .video })
        XCTAssertTrue(analysis.unassignedAttachments.contains { $0.attachmentKind == .file })
    }
    func testUnassignedSelectionRejectsCrossAccountAssignedAndNonAttachmentPaths() throws {
        let (inventory, analysis) = try environment()
        let account = inventory.accounts[0].id
        let own = try XCTUnwrap(analysis.unassignedAttachments.first { $0.accountID == account && $0.identity.links == 1 })
        let other = try XCTUnwrap(analysis.unassignedAttachments.first { $0.accountID != account })
        let assigned = try XCTUnwrap(analysis.conversations.first { $0.conversation.accountID == account }?.filePaths.first)
        let database = try XCTUnwrap(inventory.files.first { $0.category == .database })
        for path in [other.id, assigned, database.id, "../escape"] {
            XCTAssertThrowsError(try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: [own.id, path], accountID: account))
        }
        XCTAssertThrowsError(try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: [], accountID: account))
    }
    func testUnassignedCleanupAllowsHardlinksPreservesPeersAndSupportsRestore() throws {
        let (_, analysis) = try environment()
        let files = analysis.unassignedAttachments.filter { $0.accountID == "demo_account" }
        XCTAssertTrue(files.contains { $0.identity.links > 1 })
        let plan = try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: Set(files.map(\.id)), accountID: "demo_account")
        XCTAssertEqual(plan.scope, .unassignedAttachments)
        XCTAssertEqual(plan.selectedMessages, 0)
        XCTAssertEqual(plan.candidates.count, 3)
        XCTAssertEqual(plan.sharedPathCount, 1)
        XCTAssertTrue(plan.skipped.isEmpty)
        let shared = try XCTUnwrap(files.first { $0.identity.links > 1 })
        let peers = analysis.inventory.files.filter { $0.identity.physicalID == shared.identity.physicalID && $0.id != shared.id }
        XCTAssertFalse(peers.isEmpty)
        let originalData = try Data(contentsOf: analysis.inventory.url(for: shared))
        let trash = temporary.appendingPathComponent("trash")
        try FileSafety.privateDirectory(trash)
        let service = CleanupService(journalDirectory: temporary.appendingPathComponent("journal"))
        XCTAssertThrowsError(try service.execute(plan, processIsRunning: { true }, trash: { $0 }))
        let record = try service.execute(plan, processIsRunning: { false }, trash: { source in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target); return target
        })
        XCTAssertEqual(record.trashedCount, 3)
        for peer in peers {
            XCTAssertEqual(try Data(contentsOf: analysis.inventory.url(for: peer)), originalData)
            XCTAssertEqual(try FileSafety.identity(analysis.inventory.url(for: peer)), peer.identity)
        }
        XCTAssertEqual(service.records().first?.scope, .unassignedAttachments)
        let after = Analysis(inventory: try Scanner.scan(root: analysis.inventory.root), indexes: analysis.indexes)
        XCTAssertTrue(Set(after.unassignedAttachments.map(\.id)).isDisjoint(with: plan.candidates.map(\.id)))
        let restored = try service.restore(record, processIsRunning: { false })
        XCTAssertEqual(restored.restoredCount, 3)
        for file in plan.candidates {
            XCTAssertEqual(try FileSafety.identity(plan.root.appendingPathComponent(file.relativePath)), file.expectedIdentity)
        }
    }
    func testSelectedHardlinkPathsDeduplicateAllocationAndRemainSeparateCandidates() throws {
        let (_, analysis) = try environment()
        let shared = try XCTUnwrap(analysis.unassignedAttachments.first { $0.accountID == "demo_account" && $0.identity.links > 1 })
        let source = analysis.inventory.url(for: shared)
        let alias = source.deletingLastPathComponent().appendingPathComponent("second-selected-link.mp4")
        try FileManager.default.linkItem(at: source, to: alias)
        let inventory = try Scanner.scan(root: analysis.inventory.root)
        let refreshed = Analysis(inventory: inventory, indexes: analysis.indexes)
        let paths = Set(refreshed.unassignedAttachments.filter { $0.identity.physicalID == shared.identity.physicalID }.map(\.id))
        XCTAssertEqual(paths.count, 2)
        let plan = try CleanupPlanner.planUnassigned(analysis: refreshed, relativePaths: paths, accountID: "demo_account")
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(plan.sharedPathCount, 2)
        XCTAssertEqual(plan.logicalBytes, shared.identity.bytes * 2)
        XCTAssertEqual(plan.allocatedBytes, shared.allocatedBytes)
        let trash = temporary.appendingPathComponent("trash")
        try FileSafety.privateDirectory(trash)
        let service = CleanupService(journalDirectory: temporary.appendingPathComponent("journal"))
        let record = try service.execute(plan, processIsRunning: { false }, trash: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target); return target
        })
        XCTAssertEqual(record.trashedCount, 2)
        XCTAssertEqual(try service.restore(record, processIsRunning: { false }).restoredCount, 2)
        XCTAssertEqual(try FileSafety.identity(source), try FileSafety.identity(alias))
    }
    func testSharedPathSystemTrashAndRestorePreservesOtherLinks() throws {
        let (_, analysis) = try environment()
        let file = try XCTUnwrap(analysis.unassignedAttachments.first { $0.accountID == "demo_account" && $0.identity.links > 1 })
        let peer = try XCTUnwrap(analysis.inventory.files.first { $0.id != file.id && $0.identity.physicalID == file.identity.physicalID })
        let originalData = try Data(contentsOf: analysis.inventory.url(for: peer))
        let plan = try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: [file.id], accountID: "demo_account")
        let service = CleanupService(journalDirectory: temporary.appendingPathComponent("journal"))
        let record = try service.execute(plan, processIsRunning: { false })
        defer { _ = try? service.restore(record, processIsRunning: { false }) }
        XCTAssertEqual(record.trashedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.inventory.url(for: file).path))
        XCTAssertEqual(try Data(contentsOf: analysis.inventory.url(for: peer)), originalData)
        XCTAssertEqual(try FileSafety.identity(analysis.inventory.url(for: peer)), peer.identity)
        XCTAssertEqual(try service.restore(record, processIsRunning: { false }).restoredCount, 1)
        XCTAssertEqual(try FileSafety.identity(analysis.inventory.url(for: file)), file.identity)
    }
    func testUnassignedCleanupChecksFileChangesAndIndexChanges() throws {
        let (_, analysis) = try environment()
        let file = try XCTUnwrap(analysis.unassignedAttachments.first { $0.accountID == "demo_account" && $0.identity.links == 1 })
        let plan = try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: [file.id], accountID: "demo_account")
        try Data("changed".utf8).write(to: analysis.inventory.url(for: file))
        let service = CleanupService(journalDirectory: temporary.appendingPathComponent("journal"))
        let record = try service.execute(plan, processIsRunning: { false }, trash: { _ in XCTFail("Changed file must not be moved"); throw StorageError.invalid("rejected") })
        XCTAssertEqual(record.items.first?.state, "skipped")
        let indexPath = try XCTUnwrap(plan.sourceFiles.keys.first)
        try Data("changed index".utf8).write(to: plan.root.appendingPathComponent(indexPath))
        XCTAssertThrowsError(try service.execute(plan, processIsRunning: { false }, trash: { $0 }))
    }
    func testManualFileCleanupWorksWithoutUnlockedIndex() throws {
        let (inventory, _) = try environment()
        let analysis = Analysis(inventory: inventory, indexes: [])
        let file = try XCTUnwrap(analysis.unassignedAttachments.first { $0.accountID == "demo_account" && $0.identity.links == 1 })
        let plan = try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: [file.id], accountID: "demo_account")
        XCTAssertEqual(plan.candidates.count, 1)
        XCTAssertTrue(plan.sourceFiles.isEmpty)
    }
}
