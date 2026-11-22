import Foundation
import Darwin

public struct ScanProgress: Sendable {
    public let count: Int
    public let bytes: Int64
}

public enum Scanner {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data", isDirectory: true)

    public static func scan(root: URL, application: URL? = nil, related: [URL] = [],
                            progress: @Sendable (ScanProgress) -> Void = { _ in }) throws -> Inventory {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageError.invalid("请选择可访问的微信 Data、xwechat_files 或账号目录。")
        }
        let accounts = try discoverAccounts(root: root)
        guard !accounts.isEmpty || root.lastPathComponent == "Data" else {
            throw StorageError.invalid("没有发现新版微信账号目录（需要包含 db_storage）。")
        }
        let legacyAccounts = LegacyLayout.accountMap(accounts)
        var files = [StoredFile](), warnings = [String](), byteCount: Int64 = 0
        var skippedLinks = 0, blockedAccounts = Set<String>()
        let canonicalRoot = try FileSafety.canonicalPath(root)
        // Only keys the loop reads: the enumerator prefetches them in bulk with each directory listing.
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isAliasFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var parentPaths = [String: String]()
        let keySet = Set(keys)
        var lastProgress = ProcessInfo.processInfo.systemUptime
        // Stay on the root's volume, compared by device number (formatting a volume object per file was costly).
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { throw StorageError.invalid("无法读取所选目录。") }
        let rootDevice = UInt64(rootInfo.st_dev)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, error in
                if warnings.count < 50 { warnings.append("部分目录无法读取：\((error as NSError).code)") }
                return true
            })
        guard let enumerator else { throw StorageError.invalid("无法枚举目录，请检查系统授权。") }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keySet)
                if values.isSymbolicLink == true || values.isAliasFile == true {
                    // DirectoryEnumerator does not descend into symlinks/aliases. Calling
                    // skipDescendants on a non-directory can skip unrelated pending entries.
                    skippedLinks += 1
                    let parent = try FileSafety.canonicalPath(url.deletingLastPathComponent())
                    let local = String((parent + "/" + url.lastPathComponent).dropFirst(canonicalRoot.count + 1))
                    for account in accounts where account.relativePath.isEmpty || local.hasPrefix(account.relativePath + "/") {
                        blockedAccounts.insert(account.id)
                    }
                    // Legacy media is merged into the account's chats, so an unscanned link there blocks it too.
                    if let legacy = LegacyLayout.locate(local), let owner = legacyAccounts[legacy.accountHash] {
                        blockedAccounts.insert(owner)
                    }
                    continue
                }
                guard values.isRegularFile == true else {
                    // A directory on another volume is a mount point: skip it whole.
                    var metadata = stat()
                    if values.isDirectory == true, lstat(url.path, &metadata) == 0, UInt64(metadata.st_dev) != rootDevice {
                        enumerator.skipDescendants()
                        if warnings.count < 50 { warnings.append("已跳过其他磁盘卷。") }
                    }
                    continue
                }
                let identity = try FileSafety.identity(url)
                guard identity.device == rootDevice else {
                    if warnings.count < 50 { warnings.append("已跳过其他磁盘卷。") }
                    continue
                }
                let parent = url.deletingLastPathComponent()
                let resolvedParent: String
                if let cached = parentPaths[parent.path] { resolvedParent = cached }
                else { resolvedParent = try FileSafety.canonicalPath(parent); parentPaths[parent.path] = resolvedParent }
                guard resolvedParent == canonicalRoot || resolvedParent.hasPrefix(canonicalRoot + "/") else {
                    throw StorageError.invalid("扫描路径超出所选目录。")
                }
                let relative = resolvedParent == canonicalRoot ? url.lastPathComponent :
                    String(resolvedParent.dropFirst(canonicalRoot.count + 1)) + "/" + url.lastPathComponent
                let account = accounts.first { $0.relativePath.isEmpty || relative.hasPrefix($0.relativePath + "/") }
                let local = account.map { $0.relativePath.isEmpty ? relative : String(relative.dropFirst($0.relativePath.count + 1)) } ?? ""
                let parts = local.split(separator: "/").map(String.init)
                let hash = parts.count >= 4 && parts[0] == "msg" && parts[1] == "attach" && isHash(parts[2]) ? parts[2] : nil
                var accountID = account?.id, directoryHash = hash
                let category: FileCategory
                if let legacy = LegacyLayout.locate(relative), let chat = legacy.chatHash,
                   let owner = legacyAccounts[legacy.accountHash] {
                    // Old-client chat media joins the current account's conversation with the same chat hash.
                    category = .attachment; accountID = owner; directoryHash = chat
                } else if relative.contains(LegacyLayout.prefix) { category = .legacy }
                else if parts.first == "db_storage" { category = .database }
                else if parts.first == "msg" { category = .attachment }
                else if ["cache", "temp"].contains(parts.first ?? "") || relative.contains("/Caches/") { category = .cache }
                else { category = .other }
                files.append(StoredFile(relativePath: relative, identity: identity,
                    allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(identity.bytes)),
                    category: category, accountID: accountID, directoryChatHash: directoryHash))
                byteCount += identity.bytes
                if files.count.isMultiple(of: 256), ProcessInfo.processInfo.systemUptime - lastProgress >= 0.15 {
                    progress(ScanProgress(count: files.count, bytes: byteCount)); lastProgress = ProcessInfo.processInfo.systemUptime
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                if warnings.count < 50 { warnings.append("部分项目读取失败，扫描结果不完整。") }
            }
        }
        let appSize = try application.map { try directorySize($0) } ?? (0, 0, true)
        let relatedLocations = try related.compactMap { url -> RelatedLocation? in
            guard let size = try locationSize(url) else { return nil }
            return RelatedLocation(path: url.path, logicalBytes: size.0, allocatedBytes: size.1, complete: size.2)
        }
        progress(ScanProgress(count: files.count, bytes: byteCount))
        var inventory = Inventory(root: root, accounts: accounts, files: files, warnings: warnings,
            skippedLinks: skippedLinks, blockedAccountIDs: blockedAccounts,
            scannedAt: Date(), applicationBytes: appSize.0, applicationAllocatedBytes: appSize.1,
            applicationScanComplete: appSize.2)
        inventory.relatedLocations = relatedLocations
        return inventory
    }

    /// WeChat's other on-disk locations: extension and group containers, app scripts and preferences.
    /// The main container is excluded; its Data folder is the scan root.
    public static func relatedLocations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let library = home.appendingPathComponent("Library")
        let folders: [(String, (String) -> Bool)] = [
            ("Containers", { $0.hasPrefix("com.tencent.xinWeChat.") }),
            ("Group Containers", { $0.hasSuffix(".com.tencent.xinWeChat") || $0.contains(".com.tencent.xinWeChat.") }),
            ("Application Scripts", { $0.hasPrefix("com.tencent.xinWeChat") || $0.hasSuffix(".com.tencent.xinWeChat") }),
        ]
        var result = [URL]()
        for (folder, matches) in folders {
            let parent = library.appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            result += names.filter(matches).sorted().map { parent.appendingPathComponent($0) }
        }
        result.append(library.appendingPathComponent("Preferences/com.tencent.xinWeChat.plist"))
        return result.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
            return values.isSymbolicLink != true
        }
    }

    /// Size of a related folder or single file; nil when it does not exist or is a link.
    static func locationSize(_ url: URL) throws -> (Int64, Int64, Bool)? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey]),
              values.isSymbolicLink != true else { return nil }
        if values.isDirectory == true { return try directorySize(url) }
        guard values.isRegularFile == true, let identity = try? FileSafety.identity(url) else { return nil }
        return (identity.bytes, Int64(values.totalFileAllocatedSize ?? Int(identity.bytes)), true)
    }

    public static func discoverAccounts(root: URL) throws -> [Account] {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("db_storage").path) {
            return [Account(id: root.lastPathComponent, relativePath: "")]
        }
        let parent: URL
        if root.lastPathComponent == "Data" { parent = root.appendingPathComponent("Documents/xwechat_files") }
        else if root.lastPathComponent == "Documents" { parent = root.appendingPathComponent("xwechat_files") }
        else { parent = root }
        guard fm.fileExists(atPath: parent.path) else { return [] }
        return try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true &&
                    fm.fileExists(atPath: url.appendingPathComponent("db_storage").path)
            }.map { Account(id: $0.lastPathComponent, relativePath: try FileSafety.relativePath($0, root: root)) }
            .sorted { $0.id < $1.id }
    }

    static func directorySize(_ root: URL) throws -> (Int64, Int64, Bool) {
        var logical: Int64 = 0, allocated: Int64 = 0, complete = true
        var seen = Set<String>()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, _ in complete = false; return true }) {
            for case let url as URL in e {
                try Task.checkCancellation()
                guard let v = try? url.resourceValues(forKeys: keys) else { complete = false; continue }
                // The enumerator never descends into links; skipDescendants on a non-directory would
                // skip unrelated pending entries (app bundles are full of framework links).
                if v.isSymbolicLink == true { continue }
                if v.isRegularFile == true, let identity = try? FileSafety.identity(url) {
                    logical += identity.bytes
                    if seen.insert(identity.physicalID).inserted { allocated += Int64(v.totalFileAllocatedSize ?? Int(identity.bytes)) }
                }
            }
        } else { complete = false }
        return (logical, allocated, complete)
    }

    public static func isHash(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
