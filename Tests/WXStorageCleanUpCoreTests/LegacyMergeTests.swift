import XCTest
import Foundation
@testable import WXStorageCleanUpCore

/// Old-client media under Application Support joins the current account's chats without a separate "legacy" bucket.
final class LegacyMergeTests: XCTestCase {
    var temporaryDirectories = [URL]()
    let friend = "wxid_legacy_friend"
    let owner = "wxid_owner_ab12"

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WeChatLegacyTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(url); temporaryDirectories.append(url); return url
    }
    func write(_ url: URL, bytes: Int) throws {
        try FileSafety.privateDirectory(url.deletingLastPathComponent())
        try Data(repeating: 7, count: bytes).write(to: url)
    }

    /// A Data folder with current account folders and one legacy account folder named MD5(legacyUser).
    func fixture(accounts: [String]? = nil, legacyUser: String = "wxid_owner") throws -> (root: URL, legacyChat: String) {
        let accounts = accounts ?? [owner]
        let root = try temporary().appendingPathComponent("Data")
        for account in accounts {
            try FileSafety.privateDirectory(root.appendingPathComponent("Documents/xwechat_files/\(account)/db_storage"))
        }
        try write(root.appendingPathComponent("Documents/xwechat_files/\(accounts[0])/msg/attach/\(chatHash(friend))/2026-10/Img/a.dat"), bytes: 1_000)
        let legacyAccount = LegacyLayout.prefix + "2.0b4.0.9/" + chatHash(legacyUser)
        let legacyChat = legacyAccount + "/Message/MessageTemp/" + chatHash(friend)
        try write(root.appendingPathComponent(legacyChat + "/Image/1_.pic.jpg"), bytes: 2_000)
        try write(root.appendingPathComponent(legacyChat + "/Audio/2.aud.silk"), bytes: 300)
        try write(root.appendingPathComponent(legacyChat + "/Video/3.mp4"), bytes: 4_000)
        try write(root.appendingPathComponent(legacyAccount + "/Message/msg_0.db"), bytes: 500)
        return (root, legacyChat)
    }
    func namedIndex(_ inventory: Inventory) -> AccountIndex {
        let hash = chatHash(friend)
        return AccountIndex(accountID: owner, conversations: [IndexedConversation(id: "\(owner):\(hash)", accountID: owner,
            internalID: friend, directoryHash: hash, name: "旧友")], messages: [], warnings: [], sourceFingerprint: nil,
            sourceRoot: inventory.root, sourceFiles: [:], trustedBinding: true, loadedAt: Date())
    }

    func testAccountFolderSuffixIsStrippedBeforeHashing() {
        XCTAssertEqual(LegacyLayout.username(fromAccountFolder: "wxid_abc_1f2e"), "wxid_abc")
        XCTAssertEqual(LegacyLayout.username(fromAccountFolder: "custom_name_DC85"), "custom_name")
        XCTAssertNil(LegacyLayout.username(fromAccountFolder: "demo_account"))
        XCTAssertNil(LegacyLayout.username(fromAccountFolder: "_ab12"))
        XCTAssertEqual(LegacyLayout.accountMap([Account(id: "wxid_abc_1f2e", relativePath: "x")]), [chatHash("wxid_abc"): "wxid_abc_1f2e"])
    }

    func testOnlyFilesInsideAChatFolderAreChatMedia() {
        let account = chatHash("wxid_owner"), chat = chatHash(friend)
        let base = LegacyLayout.prefix + "2.0b4.0.9/" + account
        XCTAssertEqual(LegacyLayout.chatFolder(containing: base + "/Message/MessageTemp/" + chat + "/Image/1.jpg"), base + "/Message/MessageTemp/" + chat)
        XCTAssertNil(LegacyLayout.chatFolder(containing: base + "/Message/MessageTemp/" + chat))
        XCTAssertNil(LegacyLayout.chatFolder(containing: base + "/Message/MessageTemp/not-a-hash/1.jpg"))
        XCTAssertNil(LegacyLayout.chatFolder(containing: base + "/Message/msg_0.db"))
        XCTAssertNil(LegacyLayout.chatFolder(containing: "Documents/" + base + "/Message/MessageTemp/" + chat + "/1.jpg"))
        XCTAssertEqual(LegacyLayout.locate(base)?.accountHash, account)
    }

    func testLegacyMediaJoinsCurrentChatAndDatabasesStayLegacy() throws {
        let (root, legacyChat) = try fixture()
        let inventory = try Scanner.scan(root: root)
        XCTAssertTrue(inventory.complete)
        let media = inventory.files.filter { $0.relativePath.hasPrefix(legacyChat + "/") }
        XCTAssertEqual(media.count, 3)
        XCTAssertTrue(media.allSatisfy { $0.category == .attachment && $0.accountID == owner && $0.directoryChatHash == chatHash(friend) })
        XCTAssertEqual(Set(media.map(\.attachmentKind)), [.image, .voice, .video])
        let database = try XCTUnwrap(inventory.files.first { $0.name == "msg_0.db" })
        XCTAssertEqual(database.category, .legacy)
        XCTAssertNil(database.accountID)

        // Without an index the merged chat is still one directory-hash conversation.
        let unnamed = Analysis(inventory: inventory, indexes: [])
        XCTAssertEqual(unnamed.conversations.count, 1)
        XCTAssertEqual(unnamed.conversations[0].filePaths.count, 4)

        let analysis = Analysis(inventory: inventory, indexes: [namedIndex(inventory)])
        XCTAssertEqual(analysis.conversations.count, 1)
        let chat = try XCTUnwrap(analysis.conversations.first)
        XCTAssertEqual(chat.conversation.name, "旧友")
        XCTAssertEqual(chat.filePaths.count, 4)
        XCTAssertEqual(chat.logicalBytes, 1_000 + 2_000 + 300 + 4_000)
        XCTAssertTrue(analysis.unassignedAttachments.isEmpty)
        // In the overview, merged legacy media is chat attachments; only the legacy database stays "历史版本数据".
        let breakdown = analysis.storageBreakdown()
        XCTAssertEqual(breakdown.total.module("legacy")?.allocatedBytes, database.allocatedBytes)
        XCTAssertEqual(breakdown.total.module(StorageBreakdown.chatsID(owner))?.allocatedBytes, chat.occupiedBytes)
    }

    func testConversationCleanupTrashesBothChatFoldersAndRestores() throws {
        let (root, legacyChat) = try fixture()
        let inventory = try Scanner.scan(root: root)
        let analysis = Analysis(inventory: inventory, indexes: [namedIndex(inventory)])
        let chat = try XCTUnwrap(analysis.conversations.first)
        let plan = try CleanupPlanner.planConversation(analysis: analysis, conversationID: chat.id, accountID: owner)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(Set(plan.candidates.filter(\.isDirectory).map(\.relativePath)),
            ["Documents/xwechat_files/\(owner)/msg/attach/\(chatHash(friend))", legacyChat])
        XCTAssertEqual(plan.logicalBytes, chat.logicalBytes)

        let trash = try temporary()
        let service = CleanupService(journalDirectory: try temporary())
        let record = try service.execute(plan, processIsRunning: { false }, trash: { source in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target); return target
        })
        XCTAssertEqual(record.state, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(legacyChat).path))
        let legacyDatabase = LegacyLayout.prefix + "2.0b4.0.9/\(chatHash("wxid_owner"))/Message/msg_0.db"
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(legacyDatabase).path))

        let restored = try service.restore(record, processIsRunning: { false })
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(legacyChat + "/Image/1_.pic.jpg").path))
    }

    func testUnmappedOrAmbiguousLegacyAccountsStayOutOfChats() throws {
        let (root, legacyChat) = try fixture(legacyUser: "wxid_someone_else")
        let unmapped = try Scanner.scan(root: root).files.filter { $0.relativePath.hasPrefix(legacyChat + "/") }
        XCTAssertEqual(unmapped.count, 3)
        XCTAssertTrue(unmapped.allSatisfy { $0.category == .legacy && $0.accountID == nil && $0.directoryChatHash == nil })

        // Two current folders for the same username cannot prove which one owns the legacy folder.
        let (ambiguousRoot, ambiguousChat) = try fixture(accounts: [owner, "wxid_owner_cd34"])
        let ambiguous = try Scanner.scan(root: ambiguousRoot)
        let media = ambiguous.files.filter { $0.relativePath.hasPrefix(ambiguousChat + "/") }
        XCTAssertEqual(media.count, 3)
        XCTAssertTrue(media.allSatisfy { $0.category == .legacy && $0.accountID == nil })
        XCTAssertEqual(Analysis(inventory: ambiguous, indexes: []).conversations.map(\.filePaths.count), [1])
    }

    func testLinkInsideLegacyFolderBlocksOwningAccount() throws {
        let (root, legacyChat) = try fixture()
        let outside = try temporary().appendingPathComponent("secret")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(legacyChat + "/Image/link.jpg"), withDestinationURL: outside)
        let inventory = try Scanner.scan(root: root)
        XCTAssertEqual(inventory.blockedAccountIDs, [owner])
        let analysis = Analysis(inventory: inventory, indexes: [namedIndex(inventory)])
        let chat = try XCTUnwrap(analysis.conversations.first)
        XCTAssertThrowsError(try CleanupPlanner.planConversation(analysis: analysis, conversationID: chat.id, accountID: owner))
    }
}
