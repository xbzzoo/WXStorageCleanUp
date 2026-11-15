import Foundation
import CryptoKit

public enum StorageError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public func chatHash(_ identifier: String) -> String {
    Insecure.MD5.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
}

public enum FileCategory: String, Codable, CaseIterable, Sendable {
    case attachment = "聊天附件", database = "数据库", cache = "缓存及临时数据"
    case legacy = "历史版本数据", other = "其他应用数据"
}

public struct FileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let bytes: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let links: UInt64
    public var physicalID: String { "\(device):\(inode)" }
}

public struct StoredFile: Identifiable, Codable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let identity: FileIdentity
    public let allocatedBytes: Int64
    public let category: FileCategory
    public let accountID: String?
    public let directoryChatHash: String?
    public var name: String { (relativePath as NSString).lastPathComponent }
    public var modifiedAt: Date { Date(timeIntervalSince1970: TimeInterval(identity.modifiedSeconds)) }
    public var attachmentKind: MediaKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if relativePath.hasPrefix("msg/video/") || relativePath.contains("/msg/video/") || ["mp4", "mov", "m4v", "avi", "webm"].contains(ext) { return .video }
        if relativePath.contains("/Img/") || ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return .image }
        if ["amr", "silk", "aac", "m4a", "mp3", "wav"].contains(ext) { return .voice }
        return .file
    }
}

public struct Account: Identifiable, Codable, Sendable {
    public let id: String
    public let relativePath: String
}

public struct Inventory: Sendable {
    public let root: URL
    public let accounts: [Account]
    public let files: [StoredFile]
    public let warnings: [String]
    public let skippedLinks: Int
    public let blockedAccountIDs: Set<String>
    public let scannedAt: Date
    public let applicationBytes: Int64
    public let applicationAllocatedBytes: Int64
    public let applicationScanComplete: Bool
    public var logicalBytes: Int64 { files.reduce(0) { $0 + $1.identity.bytes } }
    public var allocatedBytes: Int64 {
        var seen = Set<String>()
        return files.reduce(0) { n, file in
            n + (seen.insert(file.identity.physicalID).inserted ? file.allocatedBytes : 0)
        }
    }
    public var complete: Bool { warnings.isEmpty }
    public func removing(paths: Set<String>, directoryPrefixes: [String]) -> Inventory {
        Inventory(root: root, accounts: accounts,
            files: files.filter { file in !paths.contains(file.relativePath) && !directoryPrefixes.contains { file.relativePath.hasPrefix($0) } },
            warnings: warnings, skippedLinks: skippedLinks, blockedAccountIDs: blockedAccountIDs, scannedAt: scannedAt,
            applicationBytes: applicationBytes, applicationAllocatedBytes: applicationAllocatedBytes,
            applicationScanComplete: applicationScanComplete)
    }
    public func url(for file: StoredFile) -> URL { root.appendingPathComponent(file.relativePath) }
}

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image = "图片", video = "视频", file = "文件", voice = "语音", text = "文字", other = "其他"
    public static func from(_ code: Int64) -> Self {
        switch code & 65535 {
        case 1: return .text
        case 3: return .image
        case 34: return .voice
        case 43, 62: return .video
        case 49: return .file
        default: return .other
        }
    }
}

public struct IndexedMessage: Identifiable, Codable, Sendable {
    public let id: String
    public let conversationID: String
    public let timestamp: Int64
    public let localID: String
    public let kind: MediaKind
    public let summary: String
    public var filePaths: [String]
    public var resolution: String
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

public struct IndexedConversation: Identifiable, Codable, Sendable {
    public let id: String
    public let accountID: String
    public let internalID: String?
    public let directoryHash: String
    public var name: String
    public var isGroup: Bool { internalID?.hasSuffix("@chatroom") == true }
    public var named: Bool { internalID != nil }
}

public struct AccountIndex: Sendable {
    public let accountID: String
    public let conversations: [IndexedConversation]
    public let messages: [IndexedMessage]
    public let warnings: [String]
    public let sourceFingerprint: String?
    public let sourceRoot: URL
    public let sourceFiles: [String: FileIdentity]
    public let trustedBinding: Bool
    public let loadedAt: Date
}

public struct ConversationUsage: Identifiable, Sendable {
    public let conversation: IndexedConversation
    public var id: String { conversation.id }
    public let filePaths: Set<String>
    public let indexedFilePaths: Set<String>
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let sharedBytes: Int64
    public let messageCount: Int
}

public struct Analysis: Sendable {
    public let inventory: Inventory
    public let indexes: [AccountIndex]
    public let conversations: [ConversationUsage]
    public let messages: [IndexedMessage]
    public let references: [String: Set<String>]
    public let unattributedBytes: Int64
    public let unassignedAttachments: [StoredFile]
    private let fileSizes: [String: Int64]

    public init(inventory: Inventory, indexes: [AccountIndex]) {
        self.inventory = inventory
        self.indexes = indexes
        let filesByPath = Dictionary(uniqueKeysWithValues: inventory.files.map { ($0.relativePath, $0) })
        fileSizes = filesByPath.mapValues { $0.identity.bytes }
        self.messages = indexes.flatMap(\.messages).map { original in
            var message = original
            message.filePaths = message.filePaths.filter { filesByPath[$0] != nil }
            if !original.filePaths.isEmpty && message.filePaths.isEmpty { message.resolution = "原附件已不在当前扫描范围" }
            return message
        }
        var refs = [String: Set<String>]()
        for message in messages {
            for path in message.filePaths { refs[path, default: []].insert(message.id) }
        }
        references = refs
        var conversations = Dictionary(uniqueKeysWithValues: indexes.flatMap(\.conversations).map { ($0.id, $0) })
        var pathsByChat = [String: Set<String>]()
        var indexedByChat = [String: Set<String>]()
        for file in inventory.files {
            guard let account = file.accountID, let hash = file.directoryChatHash else { continue }
            let id = "\(account):\(hash)"
            if conversations[id] == nil {
                conversations[id] = IndexedConversation(id: id, accountID: account, internalID: nil,
                    directoryHash: hash, name: "未命名会话 · \(hash.prefix(8))")
            }
            pathsByChat[id, default: []].insert(file.relativePath)
        }
        for message in messages {
            for path in message.filePaths where filesByPath[path] != nil {
                pathsByChat[message.conversationID, default: []].insert(path)
                indexedByChat[message.conversationID, default: []].insert(path)
            }
        }
        var ownersByPhysicalID = [String: Set<String>]()
        for (chat, paths) in pathsByChat {
            for path in paths {
                if let file = filesByPath[path] { ownersByPhysicalID[file.identity.physicalID, default: []].insert(chat) }
            }
        }
        let messageCounts = Dictionary(grouping: messages, by: \.conversationID).mapValues(\.count)
        var result = [ConversationUsage]()
        for (id, conversation) in conversations {
            let paths = pathsByChat[id] ?? []
            var seen = Set<String>(), allocated: Int64 = 0, shared: Int64 = 0
            for path in paths {
                guard let file = filesByPath[path], seen.insert(file.identity.physicalID).inserted else { continue }
                if (ownersByPhysicalID[file.identity.physicalID]?.count ?? 0) > 1 || file.identity.links > 1 {
                    shared += file.allocatedBytes
                } else { allocated += file.allocatedBytes }
            }
            result.append(ConversationUsage(conversation: conversation, filePaths: paths,
                indexedFilePaths: indexedByChat[id] ?? [],
                logicalBytes: paths.compactMap { filesByPath[$0]?.identity.bytes }.reduce(0, +),
                allocatedBytes: allocated, sharedBytes: shared,
                messageCount: messageCounts[id] ?? 0))
        }
        self.conversations = result.sorted { $0.logicalBytes > $1.logicalBytes }
        let allAssigned = Set(pathsByChat.values.flatMap { $0 })
        self.unassignedAttachments = inventory.files.filter {
            $0.category == .attachment && !allAssigned.contains($0.relativePath)
        }.sorted {
            $0.identity.bytes == $1.identity.bytes ? $0.relativePath < $1.relativePath : $0.identity.bytes > $1.identity.bytes
        }
        self.unattributedBytes = inventory.files.filter { !allAssigned.contains($0.relativePath) }
            .reduce(0) { $0 + $1.identity.bytes }
    }

    public func bytes(for message: IndexedMessage) -> Int64 {
        Set(message.filePaths).reduce(0) { $0 + (fileSizes[$1] ?? 0) }
    }
}

public enum SizeText {
    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
