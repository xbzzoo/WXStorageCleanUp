import XCTest
import Foundation
import CSQLite
@testable import WXStorageCleanUpCore

final class StorageTests: XCTestCase {
    var temporaryDirectories = [URL]()
    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WeChatStorageTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(url); temporaryDirectories.append(url); return url
    }
    func environment(includeUnassigned: Bool = false) throws -> (DemoEnvironment, Inventory, AccountIndex, Analysis) {
        let demo = try DemoFactory.create(parent: temporary(), includeUnassigned: includeUnassigned)
        let inventory = try Scanner.scan(root: demo.root)
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        return (demo, inventory, index, Analysis(inventory: inventory, indexes: [index]))
    }
    /// The demo's standalone unassigned files: single-file candidates without hardlinks.
    func singleFilePlan(_ analysis: Analysis, account: String) throws -> CleanupPlan {
        let paths = Set(analysis.unassignedAttachments.filter { $0.accountID == account && $0.identity.links == 1 }.map(\.relativePath))
        return try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: paths, accountID: account)
    }
    func testScanCountsFilesAndDeduplicatesHardlinks() throws {
        let (_, inventory, _, analysis) = try environment()
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.accounts.count, 1)
        XCTAssertEqual(inventory.files.filter { $0.category == .attachment }.count, 14)
        XCTAssertEqual(analysis.conversations.count, 4)
        let shared = inventory.files.filter { $0.identity.links > 1 }
        XCTAssertEqual(shared.count, 2)
        var unique = [String: Int64]()
        for file in inventory.files { unique[file.identity.physicalID] = file.allocatedBytes }
        XCTAssertEqual(inventory.allocatedBytes, unique.values.reduce(0, +))
        XCTAssertGreaterThan(analysis.unattributedBytes, 0)
    }
    func testRootCanBeDataXwechatOrAccount() throws {
        let (demo, data, _, _) = try environment()
        let xwechat = try Scanner.scan(root: demo.root.appendingPathComponent("Documents/xwechat_files"))
        let account = try Scanner.scan(root: demo.root.appendingPathComponent("Documents/xwechat_files/demo_account"))
        XCTAssertEqual(xwechat.accounts.count, 1)
        XCTAssertEqual(account.accounts[0].relativePath, "")
        XCTAssertEqual(xwechat.logicalBytes, account.logicalBytes)
        XCTAssertGreaterThan(data.logicalBytes, account.logicalBytes)
    }
    func testSymlinksAreNotFollowedAndAccountLinksBlockCleanup() throws {
        let (demo, _, _, _) = try environment()
        let outside = try temporary().appendingPathComponent("secret")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: demo.root.appendingPathComponent("shortcut"), withDestinationURL: outside)
        let inventory = try Scanner.scan(root: demo.root)
        XCTAssertTrue(inventory.complete)
        XCTAssertEqual(inventory.skippedLinks, 1)
        XCTAssertTrue(inventory.blockedAccountIDs.isEmpty)
        XCTAssertFalse(inventory.files.contains { $0.relativePath == "shortcut" })
        XCTAssertEqual(inventory.files.filter { $0.category == .attachment }.count, 14)
        let accountLink = demo.root.appendingPathComponent("Documents/xwechat_files/demo_account/msg/link")
        try FileManager.default.createSymbolicLink(at: accountLink, withDestinationURL: outside)
        let blocked = try Scanner.scan(root: demo.root)
        XCTAssertEqual(blocked.blockedAccountIDs, ["demo_account"])
        let index = try IndexReader.load(snapshot: demo.snapshot, account: blocked.accounts[0], inventory: blocked)
        let blockedAnalysis = Analysis(inventory: blocked, indexes: [index])
        let chat = try XCTUnwrap(blockedAnalysis.conversations.first { !$0.filePaths.isEmpty })
        XCTAssertThrowsError(try CleanupPlanner.planConversation(analysis: blockedAnalysis, conversationID: chat.id, accountID: "demo_account"))
    }
    func testFileSafetyRejectsTraversalAndSymlinkedParent() throws {
        let root = try temporary()
        let target = root.appendingPathComponent("file")
        try Data([1]).write(to: target)
        for path in ["../file", "/file", "a/../file", "./file", "a//file", ""] {
            XCTAssertThrowsError(try FileSafety.checkedURL(relativePath: path, root: root))
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try FileSafety.checkedURL(relativePath: "link/file", root: root))
    }
    func testIndexLoadsNamedGroupsAndMessages() throws {
        let (_, _, index, analysis) = try environment()
        XCTAssertTrue(index.trustedBinding)
        XCTAssertEqual(index.conversations.filter(\.isGroup).count, 2)
        XCTAssertTrue(index.conversations.contains { $0.name == "设计讨论群" })
        XCTAssertEqual(index.messages.filter { $0.kind == .image }.count, 13)
        XCTAssertEqual(index.messages.filter { $0.kind == .text }.count, 4)
        XCTAssertTrue(index.messages.filter { $0.kind == .image }.allSatisfy { !$0.filePaths.isEmpty })
        XCTAssertEqual(Set(analysis.conversations.flatMap(\.indexedFilePaths)).count, 14)
    }
    func testMalformedProtobufIsNeverResolved() {
        XCTAssertNil(IndexReader.imageResourceID(Data()))
        XCTAssertNil(IndexReader.imageResourceID(Data([0x12, 100, 0x0a])))
        XCTAssertNil(IndexReader.imageResourceID(Data(repeating: 255, count: 40)))
        XCTAssertNil(IndexReader.imageResourceID(Data(repeating: 0, count: 5000)))
        let identifier = String(repeating: "a", count: 32)
        let valid = Data([0x12, 34, 0x0a, 32]) + Data(identifier.utf8)
        XCTAssertEqual(IndexReader.imageResourceID(valid), identifier)
        XCTAssertNil(IndexReader.imageResourceID(valid + valid))
    }
    func testLargeAccountAnalysisWithOneThousandChatsAndOneHundredThousandMessages() throws {
        let (_, inventory, original, _) = try environment()
        let chats = (0..<1000).map { number in
            IndexedConversation(id: "bench-\(number)", accountID: original.accountID, internalID: "bench-\(number)", directoryHash: "", name: "人工聊天\(number)")
        }
        let messages = (0..<100000).map { number in
            IndexedMessage(id: "benchmark-\(number)", conversationID: chats[number % 1000].id,
                timestamp: Int64(number), localID: String(number), kind: .text,
                summary: "人工性能数据", filePaths: [], resolution: "人工数据")
        }
        let index = AccountIndex(accountID: original.accountID, conversations: chats, messages: messages,
            warnings: [], sourceFingerprint: original.sourceFingerprint, sourceRoot: original.sourceRoot,
            sourceFiles: original.sourceFiles, trustedBinding: original.trustedBinding, loadedAt: Date())
        let started = Date()
        let analysis = Analysis(inventory: inventory, indexes: [index])
        let grouped = Dictionary(grouping: analysis.messages, by: \.conversationID)
        XCTAssertEqual(grouped.count, 1000)
        XCTAssertEqual(grouped["bench-0"]?.count, 100)
        XCTAssertEqual(analysis.messages.count, 100000)
        print("PERFORMANCE artificial_chats=1000 messages=100000 analysis_and_group_seconds=\(Date().timeIntervalSince(started))")
    }

    func testConversationPreviewMatchesDirectorySizeWithoutMessageMapping() throws {
        let (_, inventory, original, _) = try environment()
        let directoryOnly = AccountIndex(accountID: original.accountID, conversations: original.conversations,
            messages: [], warnings: [], sourceFingerprint: original.sourceFingerprint, sourceRoot: original.sourceRoot,
            sourceFiles: original.sourceFiles, trustedBinding: true, loadedAt: Date())
        let analysis = Analysis(inventory: inventory, indexes: [directoryOnly])
        let chat = try XCTUnwrap(analysis.conversations.first { !$0.filePaths.isEmpty })
        let plan = try CleanupPlanner.planConversation(analysis: analysis, conversationID: chat.id, accountID: original.accountID)
        let expanded = Set(plan.candidates.flatMap { item in
            item.isDirectory ? inventory.files.filter { $0.relativePath.hasPrefix(item.relativePath + "/") }.map(\.relativePath) : [item.relativePath]
        })
        XCTAssertEqual(expanded, chat.filePaths)
        XCTAssertEqual(plan.candidates.filter(\.isDirectory).count, 1)
        XCTAssertEqual(plan.logicalBytes, chat.logicalBytes)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.scope, .conversationAttachments)
        XCTAssertThrowsError(try CleanupPlanner.planConversation(analysis: analysis, conversationID: chat.id, accountID: "other"))
    }

    func testConversationFolderTrashAndRestore() throws {
        let (_, inventory, index, analysis) = try environment()
        let chat = try XCTUnwrap(analysis.conversations.first { !$0.filePaths.isEmpty })
        let plan = try CleanupPlanner.planConversation(analysis: analysis, conversationID: chat.id, accountID: index.accountID)
        let directory = try XCTUnwrap(plan.candidates.first { $0.isDirectory })
        let trash = try temporary()
        let service = CleanupService(journalDirectory: try temporary())
        let record = try service.execute(plan, processIsRunning: { false }, trash: { source in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        })
        XCTAssertEqual(record.state, "completed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inventory.root.appendingPathComponent(directory.relativePath).path))
        XCTAssertTrue(record.items.contains { $0.isDirectory == true })
        let restored = try service.restore(record, processIsRunning: { false })
        XCTAssertEqual(restored.restoredCount, record.trashedCount)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inventory.root.appendingPathComponent(directory.relativePath).path))
    }

    func testUnboundSnapshotOnlyAllowsPreview() throws {
        let (demo, inventory, _, _) = try environment()
        try FileManager.default.removeItem(at: demo.snapshot.appendingPathComponent("source-binding.json"))
        let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        XCTAssertFalse(index.trustedBinding)
        let analysis = Analysis(inventory: inventory, indexes: [index])
        let chat = try XCTUnwrap(analysis.conversations.first { !$0.filePaths.isEmpty })
        XCTAssertThrowsError(try CleanupPlanner.planConversation(analysis: analysis, conversationID: chat.id, accountID: index.accountID))
    }
    func testSnapshotRejectsOtherAccountAndTamperedContent() throws {
        let (demo, inventory, _, _) = try environment()
        XCTAssertThrowsError(try IndexReader.load(snapshot: demo.snapshot,
            account: Account(id: "other", relativePath: inventory.accounts[0].relativePath), inventory: inventory))
        let file = demo.snapshot.appendingPathComponent("contact/contact.db")
        var content = try Data(contentsOf: file); content.append(0)
        try content.write(to: file)
        XCTAssertThrowsError(try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory))
    }
    func testChangedSourceInvalidatesSnapshot() throws {
        let (demo, inventory, _, _) = try environment()
        let file = demo.root.appendingPathComponent("Documents/xwechat_files/demo_account/db_storage/message/message_resource.db")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory))
    }
    func testExecutionAndRestoreRoundTrip() throws {
        let (_, _, index, analysis) = try environment(includeUnassigned: true)
        let actual = try singleFilePlan(analysis, account: index.accountID)
        XCTAssertEqual(actual.candidates.count, 2)
        let trash = try temporary()
        let service = CleanupService(journalDirectory: try temporary())
        let record = try service.execute(actual, processIsRunning: { false }, trash: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target); return target
        })
        XCTAssertEqual(record.trashedCount, actual.candidates.count)
        for item in actual.candidates { XCTAssertFalse(FileManager.default.fileExists(atPath: actual.root.appendingPathComponent(item.relativePath).path)) }
        let restored = try service.restore(record, processIsRunning: { false })
        XCTAssertEqual(restored.restoredCount, actual.candidates.count)
        for item in actual.candidates { XCTAssertTrue(FileManager.default.fileExists(atPath: actual.root.appendingPathComponent(item.relativePath).path)) }
    }
    func testRestoreNeverOverwritesNewFile() throws {
        let (_, _, index, analysis) = try environment(includeUnassigned: true)
        let plan = try singleFilePlan(analysis, account: index.accountID)
        let trash = try temporary(), service = CleanupService(journalDirectory: try temporary())
        let record = try service.execute(plan, processIsRunning: { false }, trash: { url in
            let target = trash.appendingPathComponent(UUID().uuidString); try FileManager.default.moveItem(at: url, to: target); return target
        })
        let source = analysis.inventory.root.appendingPathComponent(plan.candidates[0].relativePath)
        let newData = Data("new-file".utf8); try newData.write(to: source)
        let restored = try service.restore(record, processIsRunning: { false })
        XCTAssertEqual(restored.items[0].state, "conflict")
        XCTAssertEqual(try Data(contentsOf: source), newData)
    }
    func testChangedFileAndRunningProcessStopExecution() throws {
        let (_, _, index, analysis) = try environment(includeUnassigned: true)
        let plan = try singleFilePlan(analysis, account: index.accountID)
        let service = CleanupService(journalDirectory: try temporary())
        XCTAssertThrowsError(try service.execute(plan, processIsRunning: { true }, trash: { $0 }))
        let url = plan.root.appendingPathComponent(plan.candidates[0].relativePath)
        try Data("changed".utf8).write(to: url)
        let record = try service.execute(plan, processIsRunning: { false }, trash: { source in
            // This fake mover only processes unmodified files; test the changed item is never passed here.
            XCTAssertNotEqual(source, url)
            throw StorageError.invalid("deliberately refused")
        })
        XCTAssertEqual(record.items[0].state, "skipped")
        XCTAssertEqual(try Data(contentsOf: url), Data("changed".utf8))
    }
    func testInvalidKeyJSONAndSQLInjectionAreRejected() throws {
        let root = try temporary(), keyFile = root.appendingPathComponent("keys.json")
        try Data("{\"a.db\":\"';DROP TABLE x;\"}".utf8).write(to: keyFile)
        XCTAssertThrowsError(try SnapshotService.readKeys(keyFile))
        let key = String(repeating: "ab", count: 32)
        try JSONSerialization.data(withJSONObject: ["message\\message_0.db": ["enc_key": key]]).write(to: keyFile)
        XCTAssertEqual(try SnapshotService.readKeys(keyFile)["message/message_0.db"], key)
    }
    func testNativeSQLCipherSnapshotLeavesSourceUnchanged() throws {
        guard let executable = SnapshotService.sqlcipherURL() else { throw XCTSkip("SQLCipher is not installed") }
        let (demo, _, _, _) = try environment()
        let dbRoot = demo.root.appendingPathComponent("Documents/xwechat_files/demo_account/db_storage")
        let key = String(repeating: "12", count: 32)
        let names = ["contact/contact.db", "hardlink/hardlink.db", "message/message_resource.db", "message/message_0.db"]
        var keys = [String: String]()
        for name in names {
            let plain = dbRoot.appendingPathComponent(name)
            let encrypted = plain.appendingPathExtension("encrypted")
            let script = """
            .bail on
            ATTACH DATABASE \(ReadOnlyDatabase.literal(encrypted.path)) AS locked KEY "x'\(key)'";
            SELECT sqlcipher_export('locked');
            DETACH DATABASE locked;
            .quit
            """
            try SnapshotService.runSQLCipher(executable: executable, database: plain, script: script)
            try FileManager.default.removeItem(at: plain)
            try FileManager.default.moveItem(at: encrypted, to: plain)
            keys[name] = key
        }
        let sourceDigests = try Dictionary(uniqueKeysWithValues: names.map { ($0, try IndexReader.digest(dbRoot.appendingPathComponent($0))) })
        let keyFile = try temporary().appendingPathComponent("keys.json")
        try JSONSerialization.data(withJSONObject: keys).write(to: keyFile)
        let inventory = try Scanner.scan(root: demo.root)
        let snapshot = try SnapshotService.create(account: inventory.accounts[0], inventory: inventory,
            keyFile: keyFile, destination: temporary(), processIsRunning: { false })
        let index = try IndexReader.load(snapshot: snapshot, account: inventory.accounts[0], inventory: inventory)
        XCTAssertTrue(index.trustedBinding)
        XCTAssertEqual(index.conversations.count, 4)
        for name in names { XCTAssertEqual(try IndexReader.digest(dbRoot.appendingPathComponent(name)), sourceDigests[name]) }
    }

    func testFilesVideosAndCrossChatReferences() throws {
        let (_, _, _, analysis) = try environment()
        let files = analysis.messages.filter { $0.kind == .file }
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.filePaths.count == 1 })
        XCTAssertEqual(files[0].filePaths, files[1].filePaths)
        XCTAssertEqual(analysis.references[files[0].filePaths[0]]?.count, 2)
        // Each chat that references the document lists it among its attachments.
        for message in files {
            XCTAssertTrue(analysis.conversations.first { $0.id == message.conversationID }?.filePaths.contains(files[0].filePaths[0]) == true)
        }
        let video = try XCTUnwrap(analysis.messages.first { $0.kind == .video })
        XCTAssertEqual(video.filePaths.count, 1)
    }

    func testDocumentRequiresContentHashAndRejectsTraversalAndCards() throws {
        let (_, inventory, _, _) = try environment()
        let account = inventory.accounts[0]
        let card = "<msg><appmsg><type>5</type><title>项目说明.txt</title><appattach/></appmsg></msg>"
        XCTAssertTrue(try MediaResolver.resolve(xml: card, kind: .file, account: account, inventory: inventory).paths.isEmpty)
        let unsafe = "<msg><appmsg><type>6</type><title>../项目说明.txt</title><md5>\(String(repeating: "a", count: 32))</md5><appattach/></appmsg></msg>"
        XCTAssertTrue(try MediaResolver.resolve(xml: unsafe, kind: .file, account: account, inventory: inventory).paths.isEmpty)
        let noMD5 = "<msg><appmsg><type>6</type><title>项目说明.txt</title><appattach/></appmsg></msg>"
        XCTAssertTrue(try MediaResolver.resolve(xml: noMD5, kind: .file, account: account, inventory: inventory).paths.isEmpty)
        let entity = "<!DOCTYPE msg [<!ENTITY file SYSTEM 'file:///etc/passwd'>]><msg><appmsg><title>&file;</title></appmsg></msg>"
        XCTAssertTrue(try MediaResolver.resolve(xml: entity, kind: .file, account: account, inventory: inventory).paths.isEmpty)
    }

    func testChatSummaryCountsSharedAttachmentsOnce() throws {
        let (_, inventory, index, analysis) = try environment()
        let summary = try XCTUnwrap(analysis.chatSummaries()[index.accountID])
        let chats = analysis.conversations.filter { $0.conversation.accountID == index.accountID }
        let unique = Set(chats.flatMap(\.filePaths))
        let files = Dictionary(uniqueKeysWithValues: inventory.files.map { ($0.relativePath, $0) })
        XCTAssertEqual(summary.chats, chats.count)
        XCTAssertEqual(summary.namedChats, 4)
        XCTAssertEqual(summary.files, unique.count)
        XCTAssertEqual(summary.messages, index.messages.count)
        XCTAssertEqual(summary.logicalBytes, unique.reduce(0) { $0 + files[$1]!.identity.bytes })
        // The document referenced from two chats is in both chat totals but counted once here.
        XCTAssertLessThan(summary.logicalBytes, chats.reduce(0) { $0 + $1.logicalBytes })
        // The hardlinked image has two paths but one physical file.
        XCTAssertLessThan(summary.allocatedBytes, unique.reduce(0) { $0 + files[$1]!.allocatedBytes })
        XCTAssertEqual(summary.bytesByKind.values.reduce(0, +), summary.allocatedBytes)
        XCTAssertEqual(summary.exclusiveBytes + summary.sharedBytes, summary.allocatedBytes)
        XCTAssertGreaterThan(summary.bytesByKind[.image] ?? 0, 0)
        XCTAssertGreaterThan(summary.bytesByKind[.video] ?? 0, 0)
        let cleaned = try XCTUnwrap(chats.first { !$0.filePaths.isEmpty })
        XCTAssertEqual(analysis.chatSummaries(excluding: [cleaned.id])[index.accountID]?.chats, summary.chats - 1)
    }

    func testZstdMessageBodiesDecodeRepeatedly() throws {
        // A single-segment zstd frame with one raw block holding "hello".
        let frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x05, 0x29, 0x00, 0x00]) + Data("hello".utf8)
        guard MediaResolver.body(frame) != nil else { throw XCTSkip("libzstd is not available") }
        let started = Date()
        for _ in 0..<5_000 { XCTAssertEqual(MediaResolver.body(frame), "hello") }
        print("PERFORMANCE zstd_bodies=5000 seconds=\(Date().timeIntervalSince(started))")
    }

    func testSystemTrashAndRestoreForGeneratedFile() throws {
        let (_, _, index, analysis) = try environment(includeUnassigned: true)
        let file = try XCTUnwrap(analysis.unassignedAttachments.first { $0.identity.links == 1 })
        let plan = try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: [file.relativePath], accountID: index.accountID)
        let service = CleanupService(journalDirectory: try temporary())
        let record = try service.execute(plan, processIsRunning: { false })
        defer {
            // Only clean the generated fixture if the assertion below fails before restoration.
            for item in record.items {
                if let path = item.trashURL, let identity = try? FileSafety.identity(URL(fileURLWithPath: path)), identity == item.expectedIdentity {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        }
        XCTAssertEqual(record.trashedCount, 1)
        let restored = try service.restore(record, processIsRunning: { false })
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertEqual(try FileSafety.identity(plan.root.appendingPathComponent(plan.candidates[0].relativePath)), plan.candidates[0].expectedIdentity)
    }

    func testSQLiteSnapshotIncludesCommittedWAL() throws {
        guard SnapshotService.sqlcipherURL() != nil else { throw XCTSkip("SQLCipher is not installed") }
        let (demo, _, _, _) = try environment()
        let contact = demo.root.appendingPathComponent("Documents/xwechat_files/demo_account/db_storage/contact/contact.db")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(contact.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO contact VALUES('wal_user','WAL fixture','');", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contact.path + "-wal"))
        let inventory = try Scanner.scan(root: demo.root)
        let keys = try temporary().appendingPathComponent("keys.json")
        try JSONSerialization.data(withJSONObject: ["unused": String(repeating: "ab", count: 32)]).write(to: keys)
        let snapshot = try SnapshotService.create(account: inventory.accounts[0], inventory: inventory, keyFile: keys,
            destination: temporary(), processIsRunning: { false })
        let db = try ReadOnlyDatabase(snapshot.appendingPathComponent("contact/contact.db"))
        XCTAssertEqual(try db.query("SELECT username FROM contact WHERE username='wal_user'").count, 1)
    }

    func testIndexChangesAfterPlanPreventAnyMove() throws {
        let (_, _, index, analysis) = try environment(includeUnassigned: true)
        let plan = try singleFilePlan(analysis, account: index.accountID)
        let path = try XCTUnwrap(plan.sourceFiles.keys.first)
        let source = plan.root.appendingPathComponent(path)
        let writer = try FileHandle(forWritingTo: source); try writer.seekToEnd(); try writer.write(contentsOf: Data([0])); try writer.close()
        var moved = false
        let service = CleanupService(journalDirectory: try temporary())
        XCTAssertThrowsError(try service.execute(plan, processIsRunning: { false }, trash: { url in moved = true; return url }))
        XCTAssertFalse(moved)
    }
}
