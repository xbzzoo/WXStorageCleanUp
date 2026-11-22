import XCTest
import Foundation
@testable import WXStorageCleanUpCore

/// The overview's "total → modules" tree: every level adds up, and the total is all scanned WeChat usage.
final class StorageBreakdownTests: XCTestCase {
    var temporaryDirectories = [URL]()
    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WeChatBreakdownTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(url); temporaryDirectories.append(url); return url
    }
    func write(_ url: URL, bytes: Int) throws {
        try FileSafety.privateDirectory(url.deletingLastPathComponent())
        try Data(repeating: 3, count: bytes).write(to: url)
    }

    /// Demo data (with a hardlinked unassigned file) plus a file in every module, an app bundle and related locations.
    func fixture() throws -> (inventory: Inventory, analysis: Analysis, account: String) {
        let parent = try temporary()
        let demo = try DemoFactory.create(parent: parent, includeUnassigned: true)
        let account = "Documents/xwechat_files/\(demo.accountID)/"
        let files: [(String, Int)] = [
            ("Documents/app_data/radium/web/page.bin", 40_000),
            ("Documents/app_data/xplugin/plugins/ocr.bin", 30_000),
            ("Documents/app_data/crashinfo/completed/crash.dmp", 5_000),
            ("Library/Caches/profiles/cache.bin", 20_000),
            ("Documents/xwechat_files/Backup/backup.bin", 15_000),
            ("Documents/xwechat_files/all_users/login.bin", 1_000),
            (account + "business/favorite/fav.bin", 12_000),
            (account + "cache/2026-10/thumb.bin", 9_000),
            (account + "temp/InputTemp/draft.bin", 3_000),
            (account + "resource/res.bin", 2_000),
            (LegacyLayout.prefix + "2.0b4.0.9/\(chatHash("nobody"))/Message/msg_0.db", 8_000),
            ("Library/Preferences/settings.plist", 500),
        ]
        for (path, size) in files { try write(demo.root.appendingPathComponent(path), bytes: size) }
        try write(parent.appendingPathComponent("WeChat.app/Contents/MacOS/WeChat"), bytes: 50_000)
        try write(parent.appendingPathComponent("Library/Containers/com.tencent.xinWeChat.WeChatMacShare/Data/share.bin"), bytes: 700)
        try write(parent.appendingPathComponent("Library/Preferences/com.tencent.xinWeChat.plist"), bytes: 300)
        let inventory = try Scanner.scan(root: demo.root, application: parent.appendingPathComponent("WeChat.app"), related: [
            parent.appendingPathComponent("Library/Containers/com.tencent.xinWeChat.WeChatMacShare"),
            parent.appendingPathComponent("Library/Preferences/com.tencent.xinWeChat.plist"),
            parent.appendingPathComponent("Library/Containers/missing"),
        ])
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        return (inventory, Analysis(inventory: inventory, indexes: [index]), demo.accountID)
    }

    func testEveryLevelAddsUpAndTotalIsAllScannedUsage() throws {
        let (inventory, analysis, account) = try fixture()
        let breakdown = analysis.storageBreakdown()
        func check(_ module: StorageModule) {
            guard !module.children.isEmpty else { return }
            XCTAssertEqual(module.allocatedBytes, module.children.reduce(0) { $0 + $1.allocatedBytes }, module.id)
            module.children.forEach(check)
        }
        check(breakdown.total)
        XCTAssertEqual(inventory.relatedLocations.count, 2)
        XCTAssertEqual(breakdown.total.allocatedBytes, inventory.allocatedBytes + inventory.applicationAllocatedBytes +
            inventory.relatedLocations.reduce(0) { $0 + $1.allocatedBytes })
        XCTAssertTrue(breakdown.complete)
        let ids = ["browser", "plugins", "logs", "app-cache", "backup", "shared-account", "legacy", "other", "application", "related",
                   StorageBreakdown.chatsID(account), StorageBreakdown.unassignedID(account)] +
            ["database", "business", "cache", "other"].map { StorageBreakdown.accountID(account) + "/" + $0 }
        for id in ids { XCTAssertGreaterThan(breakdown.total.module(id)?.allocatedBytes ?? 0, 0, id) }
    }

    func testHardlinkedFileIsSizedOnceInChatAttachments() throws {
        let (inventory, analysis, account) = try fixture()
        let breakdown = analysis.storageBreakdown()
        let shared = try XCTUnwrap(inventory.files.first { $0.name == "共享演示附件.mp4" })
        XCTAssertGreaterThan(shared.identity.links, 1)
        let unassigned = analysis.unassignedAttachments.filter { $0.accountID == account }
        // Listed on the "其他文件" page, but its storage is already counted in chat attachments.
        XCTAssertTrue(unassigned.contains { $0.relativePath == shared.relativePath })
        let expected = unassigned.filter { $0.identity.physicalID != shared.identity.physicalID }.reduce(0) { $0 + $1.allocatedBytes }
        XCTAssertEqual(breakdown.total.module(StorageBreakdown.unassignedID(account))?.allocatedBytes, expected)
        XCTAssertGreaterThan(breakdown.sharedPhysicalFiles, 0)
    }

    func testChatModuleEqualsChatsPageTotal() throws {
        let (_, analysis, account) = try fixture()
        let summary = try XCTUnwrap(analysis.chatSummaries()[account])
        XCTAssertEqual(analysis.storageBreakdown().total.module(StorageBreakdown.chatsID(account))?.allocatedBytes, summary.allocatedBytes)
        let chats = analysis.conversations.filter { $0.conversation.accountID == account }
        XCTAssertEqual(summary.exclusiveBytes, chats.reduce(0) { $0 + $1.allocatedBytes })
        XCTAssertEqual(summary.exclusiveBytes + summary.sharedBytes, summary.allocatedBytes)
        XCTAssertGreaterThan(summary.sharedBytes, 0)
        XCTAssertEqual(summary.bytesByKind.values.reduce(0, +), summary.allocatedBytes)
    }

    func testClassificationUsesTheScannedFolderName() {
        func file(_ path: String) -> StoredFile {
            StoredFile(relativePath: path, identity: FileIdentity(device: 1, inode: 1, bytes: 1, modifiedSeconds: 0, modifiedNanos: 0, links: 1),
                       allocatedBytes: 1, category: .other, accountID: nil, directoryChatHash: nil)
        }
        func leaf(_ path: String, _ root: String) -> StorageLeaf { .classify(file(path), assigned: [], accounts: [:], rootName: root) }
        XCTAssertEqual(leaf("Backup/a.bin", "xwechat_files"), .backup)
        XCTAssertEqual(leaf("Backup/a.bin", "Data"), .otherAppData)
        XCTAssertEqual(leaf("Documents/app_data/radium/web/x", "Data"), .browser)
        XCTAssertEqual(leaf("Documents/app_data/log/mm.xlog", "Data"), .logs)
        XCTAssertEqual(leaf("Documents/app_data\\confsdk", "Data"), .otherAppData)
    }

    func testBundleSizeIsNotCutShortByFrameworkLinks() throws {
        let app = try temporary().appendingPathComponent("WeChat.app")
        let framework = app.appendingPathComponent("Contents/Frameworks/Kit.framework")
        try write(framework.appendingPathComponent("Versions/A/Kit"), bytes: 50_000)
        try write(framework.appendingPathComponent("Versions/A/Resources/info.plist"), bytes: 2_000)
        for (link, target) in [("Versions/Current", "A"), ("Kit", "Versions/Current/Kit"), ("Resources", "Versions/Current/Resources")] {
            try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent(link).path, withDestinationPath: target)
        }
        try write(app.appendingPathComponent("Contents/MacOS/WeChat"), bytes: 30_000)
        try write(app.appendingPathComponent("Contents/Resources/z.bin"), bytes: 10_000)
        let size = try Scanner.directorySize(app)
        XCTAssertEqual(size.0, 92_000)
        XCTAssertTrue(size.2)
    }

    func testRelatedLocationsAreWeChatsOtherFolders() throws {
        let home = try temporary()
        for path in ["Library/Containers/com.tencent.xinWeChat/Data/main.bin",
                     "Library/Containers/com.tencent.xinWeChat.WeChatMacShare/Data/share.bin",
                     "Library/Containers/com.tencent.meeting/Data/other.bin",
                     "Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat/group.bin",
                     "Library/Application Scripts/com.tencent.xinWeChat.WeChatFileProviderExtension/script",
                     "Library/Preferences/com.tencent.xinWeChat.plist"] {
            try write(home.appendingPathComponent(path), bytes: 10)
        }
        let found = Set(Scanner.relatedLocations(home: home).map { String($0.path.dropFirst(home.path.count + 1)) })
        XCTAssertEqual(found, ["Library/Containers/com.tencent.xinWeChat.WeChatMacShare",
                               "Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat",
                               "Library/Application Scripts/com.tencent.xinWeChat.WeChatFileProviderExtension",
                               "Library/Preferences/com.tencent.xinWeChat.plist"])
    }
}
