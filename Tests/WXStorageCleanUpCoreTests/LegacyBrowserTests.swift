import XCTest
import Foundation
@testable import WXStorageCleanUpCore

/// Browsing and cleaning "历史版本数据": the folder tree matches the overview, and cleaning never touches
/// legacy media that was merged into a current chat.
final class LegacyBrowserTests: XCTestCase {
    var temporaryDirectories = [URL]()
    let friend = "wxid_legacy_friend"
    let owner = "wxid_owner_ab12"
    let version = LegacyLayout.prefix + "2.0b4.0.9"

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WeChatLegacyBrowserTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(url); temporaryDirectories.append(url); return url
    }
    func write(_ url: URL, bytes: Int) throws {
        try FileSafety.privateDirectory(url.deletingLastPathComponent())
        try Data(repeating: 9, count: bytes).write(to: url)
    }

    /// A Data folder with one current account and a legacy account folder named MD5(legacyUser):
    /// chat media, two databases, a favorites folder, and a file at the version level outside any account folder.
    func fixture(legacyUser: String = "wxid_owner") throws -> (root: URL, account: String, chat: String) {
        let root = try temporary().appendingPathComponent("Data")
        try FileSafety.privateDirectory(root.appendingPathComponent("Documents/xwechat_files/\(owner)/db_storage"))
        let account = version + "/" + chatHash(legacyUser)
        let chat = account + "/Message/MessageTemp/" + chatHash(friend)
        let files: [(String, Int)] = [
            (chat + "/Image/1_.pic.jpg", 2_000), (chat + "/Video/2.mp4", 4_000),
            (account + "/Message/msg_0.db", 5_000), (account + "/Message/msg_1.db", 3_000),
            (account + "/Favorites/fav.db", 1_500), (account + "/Favorites/data/item.bin", 700),
            (version + "/topinfo.data", 100),
        ]
        for (path, size) in files { try write(root.appendingPathComponent(path), bytes: size) }
        return (root, account, chat)
    }
    func trashing(into folder: URL) -> (URL) throws -> URL {
        { source in
            let target = folder.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target); return target
        }
    }

    func testTreeMatchesOverviewAndLeavesOutMergedChatMedia() throws {
        let (root, account, chat) = try fixture()
        let analysis = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        let legacy = analysis.legacyData()
        let top = try XCTUnwrap(legacy.root)
        XCTAssertEqual(top.id, String(LegacyLayout.prefix.dropLast()))
        XCTAssertEqual(top.allocatedBytes, analysis.storageBreakdown().total.module("legacy")?.allocatedBytes)
        XCTAssertEqual(top.files, 5)

        let folder = try XCTUnwrap(legacy.node(account))
        XCTAssertTrue(folder.cleanable)
        XCTAssertTrue(folder.mixed, "the merged chat media lives inside this folder")
        XCTAssertEqual(folder.note, "旧版账号 · 对应新版账号 \(owner)")
        XCTAssertEqual(Set(folder.children.map(\.name)), ["Message", "Favorites"])
        XCTAssertNil(legacy.node(chat), "merged chat media is listed with its chat, not here")
        XCTAssertEqual(legacy.node(account + "/Message/msg_0.db")?.note, "聊天记录数据库")
        XCTAssertFalse(try XCTUnwrap(legacy.node(account + "/Favorites")).mixed)
        XCTAssertEqual(legacy.trail(to: account + "/Favorites").map(\.name), ["com.tencent.xinWeChat", "2.0b4.0.9", chatHash("wxid_owner"), "Favorites"])

        // Only legacy account folders are cleanable; the version folder and files beside account folders are browse-only.
        XCTAssertFalse(try XCTUnwrap(legacy.node(version)).cleanable)
        XCTAssertFalse(try XCTUnwrap(legacy.node(version + "/topinfo.data")).cleanable)
        for node in [top, try XCTUnwrap(legacy.node(version))] {
            XCTAssertEqual(node.allocatedBytes, node.children.reduce(0) { $0 + $1.allocatedBytes })
        }
    }

    func testCleaningAMixedAccountFolderKeepsChatMediaAndRestores() throws {
        let (root, account, chat) = try fixture()
        let analysis = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        // The Favorites folder is also selected through its parent; it must not become a second candidate.
        let plan = try CleanupPlanner.planLegacy(analysis: analysis, relativePaths: [account, account + "/Favorites"])
        XCTAssertEqual(plan.scope, .legacyData)
        XCTAssertEqual(Set(plan.candidates.map(\.relativePath)),
            [account + "/Favorites", account + "/Message/msg_0.db", account + "/Message/msg_1.db"])
        XCTAssertEqual(plan.candidates.first { $0.relativePath == account + "/Favorites" }?.isDirectory, true)
        XCTAssertEqual(plan.logicalBytes, 5_000 + 3_000 + 1_500 + 700)

        let service = CleanupService(journalDirectory: try temporary())
        let record = try service.execute(plan, processIsRunning: { false }, trash: trashing(into: try temporary()))
        XCTAssertEqual(record.state, "completed")
        XCTAssertEqual(record.scope, .legacyData)
        let manager = FileManager.default
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent(account + "/Favorites").path))
        XCTAssertFalse(manager.fileExists(atPath: root.appendingPathComponent(account + "/Message/msg_0.db").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent(chat + "/Image/1_.pic.jpg").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent(version + "/topinfo.data").path))

        let rescanned = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        XCTAssertNil(rescanned.legacyData().node(account))
        XCTAssertEqual(rescanned.conversations.first?.filePaths.count, 2)

        XCTAssertEqual(try service.restore(record, processIsRunning: { false }).restoredCount, 3)
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent(account + "/Favorites/data/item.bin").path))
    }

    func testUnmappedAccountFolderIsTrashedWhole() throws {
        let (root, account, chat) = try fixture(legacyUser: "wxid_someone_else")
        let analysis = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        let legacy = analysis.legacyData()
        let folder = try XCTUnwrap(legacy.node(account))
        XCTAssertFalse(folder.mixed)
        XCTAssertEqual(folder.note, "旧版账号 · 未对应到新版账号")
        XCTAssertNotNil(legacy.node(chat), "unmapped chat media stays legacy data")
        let plan = try CleanupPlanner.planLegacy(analysis: analysis, relativePaths: [account])
        XCTAssertEqual(plan.candidates.map(\.relativePath), [account])
        XCTAssertEqual(plan.candidates.first?.isDirectory, true)
        XCTAssertEqual(plan.logicalBytes, folder.logicalBytes)
        let record = try CleanupService(journalDirectory: try temporary())
            .execute(plan, processIsRunning: { false }, trash: trashing(into: try temporary()))
        XCTAssertEqual(record.trashedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(account).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(version + "/topinfo.data").path))
    }

    func testRejectsSelectionsOutsideLegacyAccountFolders() throws {
        let (root, _, chat) = try fixture()
        let analysis = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        for paths: Set<String> in [[version], [version + "/topinfo.data"], [chat], [String(LegacyLayout.prefix.dropLast())],
                                   ["Documents/xwechat_files/\(owner)/db_storage"], []] {
            XCTAssertThrowsError(try CleanupPlanner.planLegacy(analysis: analysis, relativePaths: paths), "\(paths)")
        }
    }

    func testChangedFileIsSkipped() throws {
        let (root, account, _) = try fixture()
        let analysis = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent(account + "/Message/msg_1.db"))
        let plan = try CleanupPlanner.planLegacy(analysis: analysis, relativePaths: [account + "/Message"])
        XCTAssertEqual(plan.candidates.map(\.relativePath), [account + "/Message/msg_0.db"])
        XCTAssertEqual(plan.skipped.count, 1)
    }

    func testFileSharedWithAccountDataIsSizedInTheAccount() throws {
        let (root, account, _) = try fixture(legacyUser: "wxid_someone_else")
        let database = root.appendingPathComponent(account + "/Message/msg_0.db")
        try FileManager.default.linkItem(at: database, to: root.appendingPathComponent("Documents/xwechat_files/\(owner)/db_storage/copy.db"))
        let analysis = Analysis(inventory: try Scanner.scan(root: root), indexes: [])
        let legacy = analysis.legacyData()
        let node = try XCTUnwrap(legacy.node(account + "/Message/msg_0.db"))
        XCTAssertEqual(node.allocatedBytes, 0)
        XCTAssertEqual(node.hardlinkedFiles, 1)
        XCTAssertEqual(legacy.root?.allocatedBytes, analysis.storageBreakdown().total.module("legacy")?.allocatedBytes)
    }

    func testNoLegacyDataGivesAnEmptyTree() throws {
        let demo = try DemoFactory.create(parent: try temporary())
        let analysis = Analysis(inventory: try Scanner.scan(root: demo.root), indexes: [])
        XCTAssertNil(analysis.legacyData().root)
    }
}
