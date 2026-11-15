import Foundation
import CSQLite
import CryptoKit

public struct DemoEnvironment: Sendable {
    public let root: URL
    public let snapshot: URL
    public let accountID: String
}

public struct MultiAccountDemo: Sendable {
    public let root: URL
    public let snapshots: [String: URL]
}

public enum DemoFactory {
    public static func createMultiple(parent: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatStorage/Demo"), nameSuffix: String = "", includeUnassigned: Bool = false) throws -> MultiAccountDemo {
        let first = try create(parent: parent, nameSuffix: nameSuffix, includeUnassigned: includeUnassigned)
        let accountID = "demo_second_account"
        let relative = "Documents/xwechat_files/" + accountID
        let account = first.root.appendingPathComponent(relative)
        let source = first.root.appendingPathComponent("Documents/xwechat_files/" + first.accountID)
        try FileManager.default.copyItem(at: source, to: account)
        let storage = account.appendingPathComponent("db_storage")
        try database(storage.appendingPathComponent("contact/contact.db"), sql: "UPDATE contact SET nick_name=nick_name || ' · 第二账号';")
        let snapshot = first.root.deletingLastPathComponent().appendingPathComponent("second-snapshot/db_storage")
        try FileSafety.privateDirectory(snapshot)
        let names = ["contact/contact.db", "hardlink/hardlink.db", "message/message_resource.db", "message/message_0.db"]
        var identities = [String: FileIdentity](), hashes = [String: String]()
        for name in names {
            let original = storage.appendingPathComponent(name), destination = snapshot.appendingPathComponent(name)
            try FileSafety.privateDirectory(destination.deletingLastPathComponent())
            try copyPlainDatabase(source: original, destination: destination)
            identities[relative + "/db_storage/" + name] = try FileSafety.identity(original)
            hashes[name] = try IndexReader.digest(destination)
        }
        try FileSafety.writePrivate(SnapshotBinding(version: 1, accountID: accountID, sourceRoot: first.root.path,
            sourceFiles: identities, contentHashes: hashes, createdAt: Date()), to: snapshot.appendingPathComponent("source-binding.json"))
        return MultiAccountDemo(root: first.root, snapshots: [first.accountID: first.snapshot, accountID: snapshot])
    }

    public static func create(parent: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatStorage/Demo"), nameSuffix: String = "", includeUnassigned: Bool = false) throws -> DemoEnvironment {
        let folder = parent.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent("Data")
        let accountID = "demo_account", accountRelative = "Documents/xwechat_files/" + accountID
        let account = root.appendingPathComponent(accountRelative)
        let db = account.appendingPathComponent("db_storage")
        for relative in ["contact", "message", "hardlink"] { try FileSafety.privateDirectory(db.appendingPathComponent(relative)) }
        let contacts = [("demo_design@chatroom", "设计讨论群"), ("demo_project@chatroom", "项目讨论群"),
                        ("wxid_demo_mia", "小米"), ("filehelper", "文件传输助手")].map { ($0.0, $0.1 + nameSuffix) }
        try database(db.appendingPathComponent("contact/contact.db"), sql: """
            CREATE TABLE contact(username TEXT, nick_name TEXT, remark TEXT);
            \(contacts.map { "INSERT INTO contact VALUES(\(ReadOnlyDatabase.literal($0.0)),\(ReadOnlyDatabase.literal($0.1)), '');" }.joined(separator: "\n"))
            """)
        var resourceSQL = """
            CREATE TABLE ChatName2Id(user_name TEXT);
            CREATE TABLE MessageResourceInfo(message_id INTEGER, chat_id INTEGER, message_local_id INTEGER,
                message_svr_id INTEGER, message_create_time INTEGER, message_local_type INTEGER, packed_info BLOB);
            """
        var linkSQL = """
            CREATE TABLE dir2id(username TEXT);
            CREATE TABLE image_hardlink_info_v4(file_name TEXT, dir1 INTEGER, dir2 INTEGER, type INTEGER);
            """
        var messageSQL = "CREATE TABLE Name2Id(user_name TEXT);\n"
        let now = Int64(Date().timeIntervalSince1970)
        var firstImage: URL?
        for (chatIndex, contact) in contacts.enumerated() {
            let hash = chatHash(contact.0)
            let month = "2026-10"
            resourceSQL += "INSERT INTO ChatName2Id(rowid,user_name) VALUES(\(chatIndex + 1),\(ReadOnlyDatabase.literal(contact.0)));\n"
            linkSQL += "INSERT INTO dir2id(rowid,username) VALUES(\(chatIndex * 2 + 1),'\(hash)');\n"
            linkSQL += "INSERT INTO dir2id(rowid,username) VALUES(\(chatIndex * 2 + 2),'\(month)');\n"
            messageSQL += "INSERT INTO Name2Id VALUES(\(ReadOnlyDatabase.literal(contact.0)));\n"
            let table = "Msg_" + hash
            messageSQL += "CREATE TABLE \(table)(local_id INTEGER, server_id INTEGER, create_time INTEGER, local_type INTEGER, message_content TEXT);\n"
            messageSQL += "INSERT INTO \(table) VALUES(100,200,\(now - 400),1,'演示文字消息，会保留在微信中');\n"
            for item in 0..<3 {
                let resourceID = chatHash("asset-\(chatIndex)-\(item)")
                let fileName = resourceID + ".dat"
                let image = account.appendingPathComponent("msg/attach/\(hash)/\(month)/Img/\(fileName)")
                try FileSafety.privateDirectory(image.deletingLastPathComponent())
                if chatIndex == 1 && item == 2, let firstImage {
                    try FileManager.default.linkItem(at: firstImage, to: image)
                } else {
                    try Data(repeating: UInt8(65 + chatIndex), count: (chatIndex + 1) * (item + 1) * 130_000).write(to: image)
                }
                if chatIndex == 0 && item == 0 { firstImage = image }
                // Verified field shape: outer field 2, inner field 1, a 32-hex resource identifier.
                let packed = Data([0x12, 34, 0x0a, 32]) + Data(resourceID.utf8)
                let hex = packed.map { String(format: "%02x", $0) }.joined()
                let rowID = chatIndex * 10 + item + 1
                resourceSQL += "INSERT INTO MessageResourceInfo VALUES(\(rowID),\(chatIndex + 1),\(item + 1),\(1000 + rowID),\(now - Int64(item * 86400)),3,x'\(hex)');\n"
                linkSQL += "INSERT INTO image_hardlink_info_v4 VALUES('\(fileName)',\(chatIndex * 2 + 1),\(chatIndex * 2 + 2),2);\n"
                if chatIndex == 2 && item == 0 {
                    resourceSQL += "INSERT INTO MessageResourceInfo VALUES(99,3,99,9999,\(now - 500),3,x'\(hex)');\n"
                }
            }
            if chatIndex == 3 {
                let fileContent = Data(String(repeating: "演示项目说明\n", count: 1200).utf8)
                let fileDigest = Insecure.MD5.hash(data: fileContent).map { String(format: "%02x", $0) }.joined()
                let document = account.appendingPathComponent("msg/file/2026-10/项目说明.txt")
                try FileSafety.privateDirectory(document.deletingLastPathComponent())
                try fileContent.write(to: document)
                let xml = "<msg><appmsg><type>6</type><title><![CDATA[项目说明.txt]]></title><md5>\(fileDigest)</md5><appattach><totallen>\(fileContent.count)</totallen></appattach></appmsg></msg>"
                messageSQL += "INSERT INTO \(table) VALUES(201,2001,\(now - 700),49,\(ReadOnlyDatabase.literal(xml)));\n"
                // The same local file is referenced by a different conversation, without a filesystem hardlink.
                let otherTable = "Msg_" + chatHash(contacts[1].0)
                messageSQL += "INSERT INTO \(otherTable) VALUES(202,2002,\(now - 650),49,\(ReadOnlyDatabase.literal(xml)));\n"
                let videoContent = Data(repeating: 0x56, count: 320_000)
                let videoDigest = Insecure.MD5.hash(data: videoContent).map { String(format: "%02x", $0) }.joined()
                let video = account.appendingPathComponent("msg/video/2026-10/\(videoDigest).mp4")
                try FileSafety.privateDirectory(video.deletingLastPathComponent())
                try videoContent.write(to: video)
                let videoXML = "<msg><videomsg md5=\"\(videoDigest)\" length=\"\(videoContent.count)\"/></msg>"
                messageSQL += "INSERT INTO \(table) VALUES(203,2003,\(now - 600),43,\(ReadOnlyDatabase.literal(videoXML)));\n"
            }
        }
        try database(db.appendingPathComponent("message/message_resource.db"), sql: resourceSQL)
        try database(db.appendingPathComponent("hardlink/hardlink.db"), sql: linkSQL)
        try database(db.appendingPathComponent("message/message_0.db"), sql: messageSQL)
        if includeUnassigned {
            let video = account.appendingPathComponent("msg/video/2026-10/未归属演示视频.mp4")
            try FileSafety.privateDirectory(video.deletingLastPathComponent())
            try Data(repeating: 0x56, count: 540_000).write(to: video)
            let document = account.appendingPathComponent("msg/file/2026-10/未归属演示文档.pdf")
            try Data(repeating: 0x44, count: 180_000).write(to: document)
            if let firstImage {
                try FileManager.default.linkItem(at: firstImage, to: video.deletingLastPathComponent().appendingPathComponent("共享演示附件.mp4"))
            }
        }
        let cache = root.appendingPathComponent("Documents/app_data/log/demo.log")
        try FileSafety.privateDirectory(cache.deletingLastPathComponent())
        try Data(repeating: 0x20, count: 85_000).write(to: cache)
        let snapshot = folder.appendingPathComponent("snapshot/db_storage")
        try FileSafety.privateDirectory(snapshot)
        let names = ["contact/contact.db", "message/message_resource.db", "message/message_0.db", "hardlink/hardlink.db"]
        var sourceFiles = [String: FileIdentity](), hashes = [String: String]()
        for name in names {
            let source = db.appendingPathComponent(name), destination = snapshot.appendingPathComponent(name)
            try FileSafety.privateDirectory(destination.deletingLastPathComponent())
            try copyPlainDatabase(source: source, destination: destination)
            sourceFiles[accountRelative + "/db_storage/" + name] = try FileSafety.identity(source)
            hashes[name] = try IndexReader.digest(destination)
        }
        try FileSafety.writePrivate(SnapshotBinding(version: 1, accountID: accountID, sourceRoot: root.path,
            sourceFiles: sourceFiles, contentHashes: hashes, createdAt: Date()), to: snapshot.appendingPathComponent("source-binding.json"))
        return DemoEnvironment(root: root, snapshot: snapshot, accountID: accountID)
    }

    static func database(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw StorageError.invalid("无法创建演示数据库。") }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw StorageError.invalid("无法生成演示索引。") }
    }
}
