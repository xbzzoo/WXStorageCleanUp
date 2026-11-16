import XCTest
import Foundation
@testable import WXStorageCleanUpCore

final class ImageAttachmentTests: XCTestCase {
    var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileSafety.privateDirectory(temporary)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func fixture() throws -> (DemoEnvironment, Inventory, IndexedMessage) {
        let demo = try DemoFactory.create(parent: temporary)
        let inventory = try Scanner.scan(root: demo.root)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        let chat = try XCTUnwrap(index.conversations.first { $0.internalID == "demo_design@chatroom" })
        let message = try XCTUnwrap(index.messages.first { $0.conversationID == chat.id && $0.localID == "1" })
        // These tests intentionally mutate only the artificial read-only snapshot.
        try FileManager.default.removeItem(at: demo.snapshot.appendingPathComponent("source-binding.json"))
        return (demo, inventory, message)
    }

    func testScannedImagesResolveWithoutHardlinkRecords() throws {
        let (demo, inventory, original) = try fixture()
        try DemoFactory.database(demo.snapshot.appendingPathComponent("hardlink/hardlink.db"), sql: "DELETE FROM image_hardlink_info_v4;")
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        XCTAssertEqual(index.messages.first { $0.id == original.id }?.filePaths, original.filePaths)
    }

    func testImageVariantsResolveAndOriginalPrecedesThumbnail() throws {
        let (demo, inventory, original) = try fixture()
        let source = demo.root.appendingPathComponent(try XCTUnwrap(original.filePaths.first))
        for suffix in ["_t.dat", "_h.dat"] {
            try FileManager.default.copyItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix))
        }
        let refreshed = try Scanner.scan(root: demo.root)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: refreshed)
        let paths = try XCTUnwrap(index.messages.first { $0.id == original.id }?.filePaths)
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths.first, original.filePaths.first)
        XCTAssertTrue(try XCTUnwrap(paths.last).hasSuffix("_t.dat"))
        try FileManager.default.removeItem(at: source)
        let variants = try Scanner.scan(root: demo.root)
        let variantIndex = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: variants)
        XCTAssertTrue(try XCTUnwrap(variantIndex.messages.first { $0.id == original.id }?.filePaths.first).hasSuffix("_h.dat"))
    }

    func testMissingImageDoesNotMatchOtherChatOrFilenamePrefix() throws {
        let (demo, inventory, original) = try fixture()
        let source = demo.root.appendingPathComponent(try XCTUnwrap(original.filePaths.first))
        let other = demo.root.appendingPathComponent(inventory.accounts[0].relativePath)
            .appendingPathComponent("msg/attach/\(chatHash("filehelper"))/2026-10/Img/\(source.lastPathComponent)")
        try FileSafety.privateDirectory(other.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: other)
        try FileManager.default.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + "abcdef.dat"))
        let refreshed = try Scanner.scan(root: demo.root)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: refreshed)
        XCTAssertEqual(index.messages.first { $0.id == original.id }?.filePaths, [])
    }

    func testXMLFallbackResolvesResourceAndShardOnlyImage() throws {
        let (demo, inventory, original) = try fixture()
        let identifier = chatHash("asset-0-0")
        let table = "Msg_" + chatHash("demo_design@chatroom")
        try DemoFactory.database(demo.snapshot.appendingPathComponent("message/message_resource.db"), sql: "UPDATE MessageResourceInfo SET packed_info=x'00' WHERE message_id=1;")
        let xml = "<msg><img md5=\"\(identifier)\"/></msg>"
        try DemoFactory.database(demo.snapshot.appendingPathComponent("message/message_0.db"), sql: """
            INSERT INTO \(table) VALUES(1,1001,\(original.timestamp),3,\(ReadOnlyDatabase.literal(xml)));
            INSERT INTO \(table) VALUES(501,5001,\(original.timestamp + 1),3,\(ReadOnlyDatabase.literal(xml)));
            """)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        XCTAssertEqual(index.messages.first { $0.id == original.id }?.filePaths, original.filePaths)
        XCTAssertEqual(index.messages.first { $0.localID == "501" }?.filePaths, original.filePaths)
        XCTAssertEqual(index.messages.filter { $0.conversationID == original.conversationID && $0.localID == "1" }.count, 1)
    }

    func testAmbiguousMonthsAndXMLRemainUnmatched() throws {
        let (demo, inventory, original) = try fixture()
        let path = try XCTUnwrap(original.filePaths.first)
        let other = demo.root.appendingPathComponent(path.replacingOccurrences(of: "/2026-10/", with: "/2026-09/"))
        try FileSafety.privateDirectory(other.deletingLastPathComponent())
        try FileManager.default.copyItem(at: demo.root.appendingPathComponent(path), to: other)
        let refreshed = try Scanner.scan(root: demo.root)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: refreshed)
        XCTAssertEqual(index.messages.first { $0.id == original.id }?.filePaths, [])
        let id = chatHash("asset-0-0")
        XCTAssertNil(MediaResolver.imageIdentifier("<msg><img md5=\"\(id)\"/><img md5=\"\(id)\"/></msg>"))
        XCTAssertNil(MediaResolver.imageIdentifier("<msg><appmsg><img md5=\"\(id)\"/></appmsg></msg>"))
        XCTAssertNil(MediaResolver.imageIdentifier("<!DOCTYPE msg><msg><img md5=\"\(id)\"/></msg>"))
    }

    func testOtherAccountImageCannotFillMissingLocalImage() throws {
        let demo = try DemoFactory.createMultiple(parent: temporary)
        let accountPath = demo.root.appendingPathComponent("Documents/xwechat_files/demo_account")
        let identifier = chatHash("asset-0-0")
        let local = "msg/attach/\(chatHash("demo_design@chatroom"))/2026-10/Img/\(identifier).dat"
        try FileManager.default.removeItem(at: accountPath.appendingPathComponent(local))
        let inventory = try Scanner.scan(root: demo.root)
        let account = try XCTUnwrap(inventory.accounts.first { $0.id == "demo_account" })
        let snapshot = try XCTUnwrap(demo.snapshots[account.id])
        let index = try IndexReader.load(snapshot: snapshot, account: account, inventory: inventory)
        let message = try XCTUnwrap(index.messages.first { $0.conversationID == account.id + ":" + chatHash("demo_design@chatroom") && $0.localID == "1" })
        XCTAssertTrue(message.filePaths.isEmpty)
        XCTAssertTrue(inventory.files.contains { $0.accountID != account.id && $0.name == identifier + ".dat" })
    }
}
