import Foundation
import Darwin

public struct ScanProgress: Sendable {
    public let count: Int
    public let bytes: Int64
}

public enum Scanner {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data", isDirectory: true)

    public static func scan(root: URL, application: URL? = nil,
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
        var files = [StoredFile](), warnings = [String](), byteCount: Int64 = 0
        var skippedLinks = 0, blockedAccounts = Set<String>()
        let canonicalRoot = try FileSafety.canonicalPath(root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isAliasFileKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .volumeIdentifierKey]
        var parentPaths = [String: String]()
        let keySet = Set(keys)
        var lastProgress = ProcessInfo.processInfo.systemUptime
        let rootVolume = try root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier.map { String(describing: $0) }
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
                    continue
                }
                if let volume = values.volumeIdentifier, String(describing: volume) != rootVolume {
                    enumerator.skipDescendants()
                    if warnings.count < 50 { warnings.append("已跳过其他磁盘卷。") }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let parent = url.deletingLastPathComponent()
                let resolvedParent: String
                if let cached = parentPaths[parent.path] { resolvedParent = cached }
                else { resolvedParent = try FileSafety.canonicalPath(parent); parentPaths[parent.path] = resolvedParent }
                guard resolvedParent == canonicalRoot || resolvedParent.hasPrefix(canonicalRoot + "/") else {
                    throw StorageError.invalid("扫描路径超出所选目录。")
                }
                let relative = resolvedParent == canonicalRoot ? url.lastPathComponent :
                    String(resolvedParent.dropFirst(canonicalRoot.count + 1)) + "/" + url.lastPathComponent
                let identity = try FileSafety.identity(url)
                let account = accounts.first { $0.relativePath.isEmpty || relative.hasPrefix($0.relativePath + "/") }
                let local = account.map { $0.relativePath.isEmpty ? relative : String(relative.dropFirst($0.relativePath.count + 1)) } ?? ""
                let parts = local.split(separator: "/").map(String.init)
                let hash = parts.count >= 4 && parts[0] == "msg" && parts[1] == "attach" && isHash(parts[2]) ? parts[2] : nil
                let category: FileCategory
                if relative.contains("Library/Application Support/com.tencent.xinWeChat/") { category = .legacy }
                else if parts.first == "db_storage" { category = .database }
                else if parts.first == "msg" { category = .attachment }
                else if ["cache", "temp"].contains(parts.first ?? "") || relative.contains("/Caches/") { category = .cache }
                else { category = .other }
                files.append(StoredFile(relativePath: relative, identity: identity,
                    allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? Int(identity.bytes)),
                    category: category, accountID: account?.id, directoryChatHash: hash))
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
        progress(ScanProgress(count: files.count, bytes: byteCount))
        return Inventory(root: root, accounts: accounts, files: files, warnings: warnings,
            skippedLinks: skippedLinks, blockedAccountIDs: blockedAccounts,
            scannedAt: Date(), applicationBytes: appSize.0, applicationAllocatedBytes: appSize.1,
            applicationScanComplete: appSize.2)
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
                if v.isSymbolicLink == true { e.skipDescendants(); continue }
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
