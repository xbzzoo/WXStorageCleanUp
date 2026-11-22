import Foundation
import CryptoKit

public struct SnapshotBinding: Codable, Sendable {
    public let version: Int
    public let accountID: String
    public let sourceRoot: String
    public let sourceFiles: [String: FileIdentity]
    public let contentHashes: [String: String]
    public let createdAt: Date
}

public enum IndexReader {
    /// `digestCache`: where file content digests persist between loads (the account's connection folder); nil disables it.
    public static func load(snapshot: URL, account: Account, inventory: Inventory,
                            allowUnboundPreview: Bool = true, digestCache: URL? = nil,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> AccountIndex {
        progress("正在核验索引来源与数据库内容…")
        let base = FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("db_storage").path)
            ? snapshot.appendingPathComponent("db_storage") : snapshot
        let bindingURL = base.appendingPathComponent("source-binding.json")
        var binding: SnapshotBinding?
        var trusted = false
        if FileManager.default.fileExists(atPath: bindingURL.path) {
            let decoded = try JSONDecoder().decode(SnapshotBinding.self, from: Data(contentsOf: bindingURL))
            guard decoded.version == 1, decoded.accountID == account.id,
                  URL(fileURLWithPath: decoded.sourceRoot).standardizedFileURL == inventory.root.standardizedFileURL else {
                throw StorageError.invalid("该快照不属于当前账号或扫描目录。")
            }
            for (relative, identity) in decoded.sourceFiles {
                let source = try FileSafety.checkedURL(relativePath: relative, root: inventory.root)
                guard try FileSafety.identity(source) == identity else {
                    throw StorageError.invalid("微信索引已更新，请重新退出微信并创建索引快照。")
                }
            }
            for (relative, expected) in decoded.contentHashes {
                try Task.checkCancellation()
                progress("正在校验索引内容：\(relative)")
                let file = try FileSafety.checkedURL(relativePath: relative, root: base)
                guard try digest(file) == expected else {
                    throw StorageError.invalid("导入的索引内容已变化，无法用于清理。")
                }
            }
            binding = decoded
            trusted = true
        }
        guard trusted || allowUnboundPreview else {
            throw StorageError.invalid("外部索引尚未绑定原始数据库，仅允许预览。请使用本地密钥连接微信。")
        }
        progress("正在读取联系人和图片资源索引…")
        let contactURL = try FileSafety.checkedURL(relativePath: "contact/contact.db", root: base)
        let contactDB = try ReadOnlyDatabase(contactURL)
        try contactDB.require("contact", ["username", "nick_name", "remark"])
        var nameCandidates = [String: Set<String>]()
        let contactFilter = try contactDB.columns("contact").contains("local_type") ? " WHERE local_type IS NULL OR local_type != 3" : ""
        for row in try contactDB.query("SELECT username, nick_name, remark FROM contact\(contactFilter)") {
            let id = row.text("username")
            guard !id.isEmpty else { continue }
            let remark = row.text("remark"), nick = row.text("nick_name")
            let label = remark.isEmpty ? (nick.isEmpty ? id : nick) : remark
            nameCandidates[id, default: []].insert(label)
        }
        let names = nameCandidates.mapValues { $0.count == 1 ? $0.first! : "名称不唯一，按内部标识显示" }
        let resourceDB = try ReadOnlyDatabase(try FileSafety.checkedURL(relativePath: "message/message_resource.db", root: base))
        try resourceDB.require("ChatName2Id", ["user_name"])
        try resourceDB.require("MessageResourceInfo", ["message_id", "chat_id", "message_local_id",
            "message_svr_id", "message_create_time", "message_local_type", "packed_info"])
        let resourceRows = try resourceDB.query("""
            SELECT c.user_name, i.message_id, i.message_local_id, i.message_svr_id,
                   i.message_create_time, i.message_local_type, i.packed_info
            FROM MessageResourceInfo i JOIN ChatName2Id c ON c.rowid = i.chat_id
            """)
        let chatNames = try resourceDB.query("SELECT user_name FROM ChatName2Id").map { $0.text("user_name") }
        var conversations = [String: IndexedConversation]()
        func conversation(_ internalID: String) -> String {
            let hash = chatHash(internalID), id = "\(account.id):\(hash)"
            if conversations[id] == nil {
                conversations[id] = IndexedConversation(id: id, accountID: account.id, internalID: internalID,
                    directoryHash: hash, name: nameCandidates[internalID]?.count == 1 ? (names[internalID] ?? internalID) : internalID)
            }
            return id
        }
        for internalID in chatNames where !internalID.isEmpty { _ = conversation(internalID) }
        var warnings = [String]()
        if !trusted { warnings.append("外部索引仅供预览：未核验其与当前微信原始数据库的绑定，清理已锁定。") }
        let imageResolver = ImageAttachmentResolver(account: account, inventory: inventory)
        var messages = [IndexedMessage]()
        // Resource rows contain explicit per-message identity. Do not choose the first of ambiguous joins.
        let resourceIdentityCounts = Dictionary(grouping: resourceRows) { row in
            "\(row.text("user_name"))|\(row.number("message_local_id"))|\(row.number("message_create_time"))|\(row.text("message_svr_id"))"
        }.mapValues(\.count)
        for (rowNumber, row) in resourceRows.enumerated() {
            if rowNumber % 1000 == 0 { progress("正在解析图片消息 \(rowNumber)/\(resourceRows.count)…") }
            try Task.checkCancellation()
            let internalID = row.text("user_name")
            guard !internalID.isEmpty else { continue }
            let cid = conversation(internalID), kind = MediaKind.from(row.number("message_local_type"))
            let resourceIdentity = "\(internalID)|\(row.number("message_local_id"))|\(row.number("message_create_time"))|\(row.text("message_svr_id"))"
            var paths = [String](), resolution = "此类型的原生资源索引尚未适配，未纳入清理"
            if kind == .image {
                if resourceIdentityCounts[resourceIdentity] != 1 { resolution = "消息资源存在多个匹配项，已保护" }
                else if let identifier = imageResourceID(row["packed_info"]?.data ?? Data()) {
                    let resolved = imageResolver.resolve(identifier: identifier, chat: internalID)
                    paths = resolved.paths; resolution = resolved.reason
                } else { resolution = "无法识别此消息的图片资源结构，已保护" }
            }
            messages.append(IndexedMessage(id: "\(cid)|resource|\(row.text("message_id"))", conversationID: cid,
                timestamp: row.number("message_create_time"), localID: row.text("message_local_id"),
                kind: kind, summary: "\(kind.rawValue)消息", filePaths: paths, resolution: resolution))
        }
        // Include conversations with no media resources, and text-only messages, when message shards are supplied.
        let resolverContext = MediaResolver.Context(account: account, inventory: inventory, persisted: DigestCache.read(digestCache))
        let messageFolder = base.appendingPathComponent("message")
        let shards = (try? FileManager.default.contentsOfDirectory(at: messageFolder, includingPropertiesForKeys: nil)) ?? []
        var seenShardKeys = Set<String>()
        var messageIndicesByIdentity = [String: [Int]]()
        for index in messages.indices {
            let message = messages[index]
            let key = "\(message.conversationID)|\(message.localID)|\(message.timestamp)"
            messageIndicesByIdentity[key, default: []].append(index)
        }
        for shard in shards.filter({ $0.lastPathComponent.range(of: "^message_[0-9]+\\.db$", options: .regularExpression) != nil }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            progress("正在读取消息分片：\(shard.lastPathComponent)")
            let db = try ReadOnlyDatabase(try FileSafety.checkedURL(relativePath: "message/" + shard.lastPathComponent, root: base))
            guard (try db.columns("Name2Id")).contains("user_name") else { continue }
            let tables = Set(try db.query("SELECT name FROM sqlite_master WHERE type='table'").map { $0.text("name") })
            let chatRows = try db.query("SELECT user_name FROM Name2Id")
            for (chatNumber, nameRow) in chatRows.enumerated() {
                try Task.checkCancellation()
                if chatNumber % 20 == 0 { progress("正在解析 \(shard.lastPathComponent)：聊天 \(chatNumber + 1)/\(chatRows.count)，含文件内容校验…") }
                let username = nameRow.text("user_name")
                guard !username.isEmpty else { continue }
                let table = "Msg_" + chatHash(username)
                guard tables.contains(table) else { continue }
                let cid = conversation(username)
                guard ["local_id", "create_time", "local_type"].allSatisfy(try db.columns(table).contains) else { continue }
                let columns = try db.columns(table)
                let fields = columns.contains("message_content") ? ", message_content" : ""
                let rows = try db.query("SELECT local_id, create_time, local_type\(fields) FROM \(ReadOnlyDatabase.identifier(table))")
                for row in rows {
                    let kind = MediaKind.from(row.number("local_type"))
                    let raw = MediaResolver.body(row["message_content"]?.data)
                    let localID = row.text("local_id"), time = row.number("create_time")
                    let identity = "\(cid)|\(localID)|\(time)"
                    let existingIndices = messageIndicesByIdentity[identity] ?? []
                    if !seenShardKeys.insert(identity).inserted {
                        for index in existingIndices { messages[index].filePaths = []; messages[index].resolution = "消息在分片中不唯一，已保护" }
                        continue
                    }
                    if existingIndices.count > 1 { continue }
                    if kind == .image {
                        // Resource metadata may not describe the locally retained variant.
                        // Fall back to the explicit image MD5 in this message's XML.
                        if let index = existingIndices.first {
                            guard messages[index].kind == .image, messages[index].filePaths.isEmpty,
                                  messages[index].resolution != "消息资源存在多个匹配项，已保护" else { continue }
                            if let identifier = MediaResolver.imageIdentifier(raw) {
                                let resolved = imageResolver.resolve(identifier: identifier, chat: username)
                                if !resolved.paths.isEmpty {
                                    messages[index].filePaths = resolved.paths; messages[index].resolution = resolved.reason
                                }
                            }
                        } else {
                            let resolved = MediaResolver.imageIdentifier(raw).map { imageResolver.resolve(identifier: $0, chat: username) }
                            messageIndicesByIdentity[identity, default: []].append(messages.count)
                            messages.append(IndexedMessage(id: "\(cid)|\(shard.lastPathComponent)|\(localID)|\(time)",
                                conversationID: cid, timestamp: time, localID: localID, kind: kind, summary: "图片消息",
                                filePaths: resolved?.paths ?? [], resolution: resolved?.reason ?? "尚未识别此消息的图片资源标识"))
                        }
                        continue
                    }
                    let resolved = try MediaResolver.resolve(xml: raw, kind: kind, account: account, inventory: inventory, context: resolverContext)
                    let summary = kind == .text ? String((raw ?? "文字消息（正文未解码）").prefix(120)) : resolved.summary
                    if let index = existingIndices.first {
                        if messages[index].kind == kind {
                            let old = messages[index]
                            messages[index] = IndexedMessage(id: old.id, conversationID: cid, timestamp: time, localID: localID,
                                kind: kind, summary: summary, filePaths: resolved.paths,
                                resolution: kind == .text ? "保留文字与消息条目" : resolved.reason)
                        }
                        continue
                    }
                    messageIndicesByIdentity[identity, default: []].append(messages.count)
                    messages.append(IndexedMessage(id: "\(cid)|\(shard.lastPathComponent)|\(row.text("local_id"))|\(row.number("create_time"))",
                        conversationID: cid, timestamp: row.number("create_time"), localID: row.text("local_id"),
                        kind: kind, summary: summary, filePaths: resolved.paths,
                        resolution: kind == .text ? "保留文字与消息条目" : resolved.reason))
                }
            }
        }
        if let digestCache { DigestCache.write(resolverContext.digests, to: digestCache) }
        warnings.append("已适配普通图片，以及消息校验值与本地内容一致的文件和视频；语音、转发内媒体和共享数据库空间未完整覆盖。")
        return AccountIndex(accountID: account.id, conversations: Array(conversations.values),
            messages: messages.sorted { $0.timestamp > $1.timestamp }, warnings: warnings,
            sourceFingerprint: binding.map { _ in "local-snapshot-v1" }, sourceRoot: inventory.root,
            sourceFiles: binding?.sourceFiles ?? [:], trustedBinding: trusted, loadedAt: Date())
    }

    static func validMonth(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        return value.count == 7 && parts.count == 2 && parts[0].count == 4 &&
            Int(parts[0]) != nil && (1...12).contains(Int(parts[1]) ?? 0)
    }

    public static func imageResourceID(_ data: Data) -> String? {
        guard data.count <= 4096, let outer = try? protoFields(data),
              outer.filter({ $0.0 == 2 }).count == 1,
              let bytes = outer.first(where: { $0.0 == 2 })?.1,
              let inner = try? protoFields(bytes), inner.filter({ $0.0 == 1 }).count == 1,
              let value = inner.first(where: { $0.0 == 1 })?.1,
              let text = String(data: value, encoding: .ascii), Scanner.isHash(text.lowercased()) else { return nil }
        return text.lowercased()
    }

    private static func protoFields(_ data: Data) throws -> [(Int, Data)] {
        let bytes = Array(data); var offset = 0; var result = [(Int, Data)]()
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw StorageError.invalid("截断的资源索引") }
                let byte = bytes[offset]; offset += 1
                if shift == 63 && byte > 1 { throw StorageError.invalid("无效资源索引") }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw StorageError.invalid("无效资源索引")
        }
        while offset < bytes.count {
            let key = try varint(), field = Int(key >> 3), wire = key & 7
            guard field > 0 else { throw StorageError.invalid("无效资源索引") }
            if wire == 0 { _ = try varint(); continue }
            let size: Int
            switch wire {
            case 1: size = 8
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count) else { throw StorageError.invalid("资源索引过长") }
                size = Int(length)
            case 5: size = 4
            default: throw StorageError.invalid("不支持的资源索引")
            }
            guard size <= bytes.count - offset else { throw StorageError.invalid("截断的资源索引") }
            if wire == 2 { result.append((field, Data(bytes[offset..<(offset + size)]))) }
            offset += size
        }
        return result
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
