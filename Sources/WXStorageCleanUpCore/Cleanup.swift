import Foundation
import Darwin

public struct CleanupCandidate: Codable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let expectedIdentity: FileIdentity
    public let parentIdentity: DirectoryIdentity
    public let allocatedBytes: Int64
    public var isDirectory = false
    public var contentBytes: Int64? = nil
}

public struct DirectoryIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StorageError.invalid("父目录已变化。") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw StorageError.invalid("父目录不可访问。") }
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino)
    }
}

public enum CleanupScope: String, Codable, Sendable {
    case messages, unassignedAttachments, conversationAttachments
}

public struct CleanupPlan: Identifiable, Sendable {
    public let id: UUID
    public let root: URL
    public let sourceFiles: [String: FileIdentity]
    public let candidates: [CleanupCandidate]
    public let skipped: [String]
    public let selectedMessages: Int
    public let accountIDs: [String]
    public let createdAt: Date
    public let scope: CleanupScope
    public var conversationID: String? = nil
    public var includesOtherReferences = false
    public var logicalBytes: Int64 { candidates.reduce(0) { $0 + ($1.contentBytes ?? $1.expectedIdentity.bytes) } }
    public var allocatedBytes: Int64 {
        var seen = Set<String>()
        return candidates.reduce(0) { $0 + (seen.insert($1.expectedIdentity.physicalID).inserted ? $1.allocatedBytes : 0) }
    }
    public var sharedPathCount: Int { candidates.filter { !$0.isDirectory && $0.expectedIdentity.links > 1 }.count }
}

public enum CleanupPlanner {
    public static func plan(analysis: Analysis, conversationIDs: Set<String> = [], messageIDs: Set<String> = [],
                            allowedAccountID: String? = nil, includeOtherReferences: Bool = false) throws -> CleanupPlan {
        guard analysis.inventory.complete else {
            throw StorageError.invalid("扫描存在未读取的目录，无法验证引用范围。请解决授权问题后重新扫描。")
        }
        let selected = analysis.messages.filter { conversationIDs.contains($0.conversationID) || messageIDs.contains($0.id) }
        let selectedIDs = Set(selected.map(\.id))
        guard !selected.isEmpty else { throw StorageError.invalid("请选择聊天或已建立附件映射的消息。") }
        var wanted = Set(selected.flatMap(\.filePaths))
        let files = Dictionary(uniqueKeysWithValues: analysis.inventory.files.map { ($0.relativePath, $0) })
        let selectedChats = Set(selected.map(\.conversationID))
        let accountIDs = Set(analysis.conversations.filter { selectedChats.contains($0.id) }.map { $0.conversation.accountID })
        if let allowedAccountID, accountIDs != [allowedAccountID] {
            throw StorageError.invalid("清理选择包含其他账号，请重新选择当前账号内的聊天或消息。")
        }
        guard accountIDs.isDisjoint(with: analysis.inventory.blockedAccountIDs) else {
            throw StorageError.invalid("所选账号内存在未扫描的目录链接，无法验证完整归属，清理已锁定。")
        }
        var sourceFiles = [String: FileIdentity]()
        for index in analysis.indexes where accountIDs.contains(index.accountID) {
            guard index.trustedBinding else { throw StorageError.invalid("该账号的外部索引仅供预览，请先用本地密钥连接当前微信索引。") }
            sourceFiles.merge(index.sourceFiles) { first, _ in first }
        }
        if includeOtherReferences {
            let physicalIDs = Set(wanted.compactMap { files[$0]?.identity.physicalID })
            for file in analysis.inventory.files where file.category == .attachment &&
                file.accountID.map({ accountIDs.contains($0) }) == true && physicalIDs.contains(file.identity.physicalID) {
                wanted.insert(file.relativePath)
            }
        }
        var candidates = [CleanupCandidate](), skipped = [String]()
        let unresolved = selected.filter { $0.kind != .text && $0.filePaths.isEmpty }.count
        if unresolved > 0 { skipped.append("\(unresolved) 条消息没有唯一的本地附件映射，已保护。") }
        for path in wanted.sorted() {
            guard let file = files[path], file.category == .attachment else {
                skipped.append("有项目不属于可处理的聊天附件范围。"); continue
            }
            guard includeOtherReferences || (analysis.references[path]?.isSubset(of: selectedIDs) == true) else {
                skipped.append("\(file.name)：还有未选中的消息引用，已保护。"); continue
            }
            let url = try FileSafety.checkedURL(relativePath: path, root: analysis.inventory.root)
            guard try FileSafety.identity(url) == file.identity else {
                skipped.append("\(file.name)：文件已变化，请重新扫描。"); continue
            }
            candidates.append(CleanupCandidate(relativePath: path, expectedIdentity: file.identity,
                parentIdentity: try DirectoryIdentity(url: url.deletingLastPathComponent()), allocatedBytes: file.allocatedBytes))
        }
        return CleanupPlan(id: UUID(), root: analysis.inventory.root, sourceFiles: sourceFiles,
            candidates: candidates, skipped: skipped, selectedMessages: selected.count, accountIDs: accountIDs.sorted(), createdAt: Date(), scope: .messages, includesOtherReferences: includeOtherReferences)
    }

    /// The exact same paths and logical bytes displayed in ConversationUsage.
    public static func planConversation(analysis: Analysis, conversationID: String, accountID: String) throws -> CleanupPlan {
        guard analysis.inventory.complete, !analysis.inventory.blockedAccountIDs.contains(accountID) else {
            throw StorageError.invalid("扫描范围不完整，请重新扫描后清理。")
        }
        guard let chat = analysis.conversations.first(where: { $0.id == conversationID && $0.conversation.accountID == accountID }) else {
            throw StorageError.invalid("聊天不属于当前账号，请重新选择。")
        }
        var sources = [String: FileIdentity]()
        for index in analysis.indexes where index.accountID == accountID {
            guard index.trustedBinding else { throw StorageError.invalid("外部索引仅供预览，请先连接本地账号。") }
            sources.merge(index.sourceFiles) { first, _ in first }
        }
        let files = Dictionary(uniqueKeysWithValues: analysis.inventory.files.map { ($0.relativePath, $0) })
        var candidates = [CleanupCandidate]()
        guard let account = analysis.inventory.accounts.first(where: { $0.id == accountID }) else { throw StorageError.invalid("当前账号不存在。") }
        let base = account.relativePath.isEmpty ? "msg/attach/" : account.relativePath + "/msg/attach/"
        var folder: String?
        if Scanner.isHash(chat.conversation.directoryHash) {
            let path = base + chat.conversation.directoryHash
            if FileManager.default.fileExists(atPath: analysis.inventory.root.appendingPathComponent(path).path) {
                let url = try FileSafety.checkedURL(relativePath: path, root: analysis.inventory.root)
                let contained = analysis.inventory.files.filter { $0.relativePath.hasPrefix(path + "/") }
                guard contained.allSatisfy({ $0.accountID == accountID && $0.category == .attachment }) else {
                    throw StorageError.invalid("聊天目录包含范围外的数据，请重新扫描。")
                }
                candidates.append(CleanupCandidate(relativePath: path, expectedIdentity: try directoryFileIdentity(url),
                    parentIdentity: try DirectoryIdentity(url: url.deletingLastPathComponent()),
                    allocatedBytes: contained.reduce(0) { $0 + $1.allocatedBytes }, isDirectory: true,
                    contentBytes: contained.reduce(0) { $0 + $1.identity.bytes }))
                folder = path
            }
        }
        for path in chat.filePaths.sorted() {
            if let folder, path.hasPrefix(folder + "/") { continue }
            try Task.checkCancellation()
            guard let file = files[path], file.accountID == accountID, file.category == .attachment else {
                throw StorageError.invalid("聊天附件范围不一致，请重新扫描。")
            }
            let url = try FileSafety.checkedURL(relativePath: path, root: analysis.inventory.root)
            guard try FileSafety.identity(url) == file.identity else {
                throw StorageError.invalid("附件已变化，请重新扫描后预览。")
            }
            candidates.append(CleanupCandidate(relativePath: path, expectedIdentity: file.identity,
                parentIdentity: try DirectoryIdentity(url: url.deletingLastPathComponent()), allocatedBytes: file.allocatedBytes))
        }
        return CleanupPlan(id: UUID(), root: analysis.inventory.root, sourceFiles: sources,
            candidates: candidates, skipped: [], selectedMessages: chat.messageCount, accountIDs: [accountID],
            createdAt: Date(), scope: .conversationAttachments, conversationID: conversationID)
    }

    /// Explicit file selection, independent of message ownership. Unassigned is not proof of disuse.
    public static func planUnassigned(analysis: Analysis, relativePaths: Set<String>, accountID: String) throws -> CleanupPlan {
        guard analysis.inventory.complete else { throw StorageError.invalid("扫描存在未读取的目录，请解决授权问题后重新扫描。") }
        guard analysis.inventory.accounts.contains(where: { $0.id == accountID }), !relativePaths.isEmpty else {
            throw StorageError.invalid("请选择当前账号的其他文件。")
        }
        guard !analysis.inventory.blockedAccountIDs.contains(accountID) else {
            throw StorageError.invalid("所选账号内存在未扫描的目录链接，请解决后重新扫描。")
        }
        let allowed = Dictionary(uniqueKeysWithValues: analysis.unassignedAttachments.map { ($0.relativePath, $0) })
        // Validate every selection; a stale or cross-account selection must never become a different plan.
        guard relativePaths.allSatisfy({ allowed[$0]?.accountID == accountID && analysis.references[$0] == nil }) else {
            throw StorageError.invalid("选择包含其他账号、已归属附件或非附件文件，请重新扫描并选择。")
        }
        var candidates = [CleanupCandidate](), skipped = [String](), sourceFiles = [String: FileIdentity]()
        for index in analysis.indexes where index.accountID == accountID && index.trustedBinding {
            sourceFiles.merge(index.sourceFiles) { first, _ in first }
        }
        for path in relativePaths.sorted() {
            guard let file = allowed[path] else { continue }
            let url = try FileSafety.checkedURL(relativePath: path, root: analysis.inventory.root)
            guard try FileSafety.identity(url) == file.identity else {
                skipped.append("\(file.name)：文件已变化，请重新扫描。"); continue
            }
            candidates.append(CleanupCandidate(relativePath: path, expectedIdentity: file.identity,
                parentIdentity: try DirectoryIdentity(url: url.deletingLastPathComponent()), allocatedBytes: file.allocatedBytes))
        }
        return CleanupPlan(id: UUID(), root: analysis.inventory.root, sourceFiles: sourceFiles,
            candidates: candidates, skipped: skipped, selectedMessages: 0, accountIDs: [accountID],
            createdAt: Date(), scope: .unassignedAttachments)
    }
}

public struct JournalItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sourceRelativePath: String
    public let expectedIdentity: FileIdentity
    public var trashURL: String?
    public var state: String
    public var error: String?
    public var isDirectory: Bool? = nil
}

public struct CleanupRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let root: String
    public let createdAt: Date
    public let logicalBytes: Int64
    public var state: String
    public var items: [JournalItem]
    public var notes: [String]
    public var accountIDs: [String]? = nil
    public var scope: CleanupScope? = nil
    public var trashedCount: Int { items.filter { $0.state == "trashed" }.count }
    public var restoredCount: Int { items.filter { $0.state == "restored" }.count }
}

public struct CleanupService: Sendable {
    public let journalDirectory: URL
    public init(journalDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatStorage/Operations")) {
        self.journalDirectory = journalDirectory
    }

    public func execute(_ plan: CleanupPlan, processIsRunning: () -> Bool = WeChatProcess.isRunning,
                        trash: (URL) throws -> URL = CleanupService.systemTrash) throws -> CleanupRecord {
        guard !plan.candidates.isEmpty else { throw StorageError.invalid("本次没有可清理的附件。") }
        guard !processIsRunning() else { throw StorageError.invalid("请先用 ⌘Q 退出微信；仅关闭窗口不会退出。") }
        guard Date().timeIntervalSince(plan.createdAt) < 15 * 60 else { throw StorageError.invalid("清理预览已过期，请重新生成。") }
        try FileSafety.privateDirectory(journalDirectory)
        try validateSource(plan)
        var record = CleanupRecord(id: plan.id, root: plan.root.path, createdAt: Date(),
            logicalBytes: plan.logicalBytes, state: "running", items: plan.candidates.map {
                JournalItem(id: UUID(), sourceRelativePath: $0.relativePath,
                    expectedIdentity: $0.expectedIdentity, trashURL: nil, state: "pending", error: nil, isDirectory: $0.isDirectory)
            }, notes: plan.skipped, accountIDs: plan.accountIDs, scope: plan.scope)
        try save(record)
        for index in plan.candidates.indices {
            if Task.isCancelled || processIsRunning() {
                record.state = "interrupted"
                record.notes.append("操作已停止，尚未开始的项目保持原位。")
                try save(record); return record
            }
            let item = plan.candidates[index]
            do {
                try validateSource(plan)
                let url = try FileSafety.checkedURL(relativePath: item.relativePath, root: plan.root)
                guard try (item.isDirectory ? directoryFileIdentity(url) : FileSafety.identity(url)) == item.expectedIdentity,
                      try DirectoryIdentity(url: url.deletingLastPathComponent()) == item.parentIdentity else {
                    throw StorageError.invalid("文件或父目录已变化，已跳过。")
                }
                guard !processIsRunning() else { throw StorageError.invalid("微信已重新启动，已跳过。") }
                record.items[index].state = "prepared"
                try save(record)
                let trashURL = try trash(url)
                record.items[index].trashURL = trashURL.path
                record.items[index].state = "trashed"
            } catch {
                if record.items[index].state == "prepared" {
                    record.items[index].state = FileManager.default.fileExists(atPath: plan.root.appendingPathComponent(item.relativePath).path)
                        ? "failed" : "indeterminate"
                } else { record.items[index].state = "skipped" }
                record.items[index].error = error.localizedDescription
            }
            // A failed journal write aborts the operation instead of deleting further files.
            try save(record)
        }
        record.state = record.items.allSatisfy { $0.state == "trashed" } ? "completed" : "partial"
        try save(record)
        return record
    }

    private func validateSource(_ plan: CleanupPlan) throws {
        for (path, expected) in plan.sourceFiles {
            let url = try FileSafety.checkedURL(relativePath: path, root: plan.root)
            guard try FileSafety.identity(url) == expected else {
                throw StorageError.invalid("微信索引已更新，请重新连接并生成清理计划。")
            }
        }
    }

    public func restore(_ existing: CleanupRecord, processIsRunning: () -> Bool = WeChatProcess.isRunning) throws -> CleanupRecord {
        guard !processIsRunning() else { throw StorageError.invalid("请先退出微信再恢复附件。") }
        var record = existing
        let root = URL(fileURLWithPath: record.root)
        for index in record.items.indices where record.items[index].state == "trashed" || record.items[index].state == "conflict" {
            if Task.isCancelled || processIsRunning() { break }
            let item = record.items[index]
            do {
                guard let path = item.trashURL else { throw StorageError.invalid("未记录废纸篓实际位置。") }
                let trashURL = URL(fileURLWithPath: path)
                guard try (item.isDirectory == true ? directoryFileIdentity(trashURL) : FileSafety.identity(trashURL)) == item.expectedIdentity else { throw StorageError.invalid("废纸篓项目已变化或不存在。") }
                let source = root.appendingPathComponent(item.sourceRelativePath)
                let parent = (item.sourceRelativePath as NSString).deletingLastPathComponent
                if !parent.isEmpty { _ = try FileSafety.checkedURL(relativePath: parent, root: root) }
                let leaf = (item.sourceRelativePath as NSString).lastPathComponent
                guard !leaf.isEmpty, leaf != ".", leaf != "..", !item.sourceRelativePath.hasPrefix("/"),
                      !item.sourceRelativePath.split(separator: "/").contains("..") else { throw StorageError.invalid("恢复路径无效。") }
                guard !FileManager.default.fileExists(atPath: source.path) else {
                    record.items[index].state = "conflict"; record.items[index].error = "原位置已有文件，不覆盖。"; try save(record); continue
                }
                record.items[index].state = "restore-prepared"
                try save(record)
                try FileManager.default.moveItem(at: trashURL, to: source)
                record.items[index].state = "restored"
                record.items[index].error = nil
            } catch {
                record.items[index].state = record.items[index].state == "restore-prepared" ? "indeterminate" : "unavailable"
                record.items[index].error = error.localizedDescription
            }
            try save(record)
        }
        try save(record)
        return record
    }

    public func records() -> [CleanupRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), var record = try? JSONDecoder().decode(CleanupRecord.self, from: data) else { return nil }
            if record.state == "running" { record.state = "interrupted" }
            for index in record.items.indices where ["prepared", "restore-prepared"].contains(record.items[index].state) {
                record.items[index].state = "indeterminate"
                record.items[index].error = "操作中断，需人工核对文件位置。"
            }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private func save(_ record: CleanupRecord) throws {
        try FileSafety.privateDirectory(journalDirectory)
        try FileSafety.writePrivate(record, to: journalDirectory.appendingPathComponent(record.id.uuidString + ".json"))
    }
    public static func systemTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw StorageError.invalid("系统未返回废纸篓位置，需人工核查。") }
        return result as URL
    }
}

private func directoryFileIdentity(_ url: URL) throws -> FileIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
        throw StorageError.invalid("聊天文件夹已变化或不是普通目录。")
    }
    return FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), bytes: Int64(metadata.st_size),
        modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec), modifiedNanos: Int64(metadata.st_mtimespec.tv_nsec), links: UInt64(metadata.st_nlink))
}
