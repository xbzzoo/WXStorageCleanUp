import Foundation
import AppKit
import Darwin

public enum WeChatProcess {
    public static func isRunning() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { app in
            let identifier = app.bundleIdentifier ?? ""
            let path = app.executableURL?.path ?? ""
            let name = app.localizedName ?? ""
            return identifier == "com.tencent.xinWeChat" || identifier.hasPrefix("com.tencent.xinWeChat.") ||
                path.contains("/WeChat.app/") || ["WeChat", "WeChatAppEx", "微信"].contains(name)
        }) { return true }
        // Helpers may outlive the main GUI and need not appear in runningApplications.
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.xinWeChat")?.path
        let roots = [installed, "/Applications/WeChat.app", "/Applications/微信.app"].compactMap { $0 }.map { $0 + "/" }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return true }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let bytes = Int32(pids.count * MemoryLayout<Int32>.stride)
        let found = proc_listallpids(&pids, bytes)
        guard found > 0, found <= pids.count else { return true }
        for pid in pids.prefix(Int(found)) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if roots.contains(where: { path.hasPrefix($0) }) { return true }
            }
        }
        return false
    }
}

public enum SnapshotService {
    static var developmentDependencyRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/dependencies/prefix")
    }
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WeChatStorage/Snapshots")
    }
    public static func sqlcipherURL() -> URL? {
        let paths: [String?] = [Bundle.main.resourceURL.map { $0.appendingPathComponent("sqlcipher").path },
            developmentDependencyRoot.appendingPathComponent("bin/sqlcipher").path,
            "/opt/homebrew/bin/sqlcipher", "/usr/local/bin/sqlcipher"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func create(account: Account, inventory: Inventory, keyFile: URL,
                              destination: URL = defaultDirectory,
                              processIsRunning: () -> Bool = WeChatProcess.isRunning,
                              progress: @Sendable (String) -> Void = { _ in }) throws -> URL {
        guard !processIsRunning() else { throw StorageError.invalid("请先用 ⌘Q 退出微信，再连接聊天索引。") }
        guard let executable = sqlcipherURL() else {
            throw StorageError.invalid("本机缺少 SQLCipher。请先安装 SQLCipher，或导入已解密索引进行预览。")
        }
        let keys = try readKeys(keyFile)
        let accountRoot = inventory.root.appendingPathComponent(account.relativePath)
        let databaseRoot = accountRoot.appendingPathComponent("db_storage")
        let databaseNames = try requiredDatabases(databaseRoot)
        let operationRoot = destination.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let encrypted = operationRoot.appendingPathComponent("encrypted", isDirectory: true)
        let output = operationRoot.appendingPathComponent("db_storage", isDirectory: true)
        try FileSafety.privateDirectory(encrypted)
        try FileSafety.privateDirectory(output)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: operationRoot) } }
        var identities = [String: FileIdentity](), hashes = [String: String]()
        for (index, relative) in databaseNames.enumerated() {
            try Task.checkCancellation()
            guard !processIsRunning() else { throw StorageError.invalid("微信已重新启动，已中止索引快照。") }
            progress("复制本地索引 \(index + 1)/\(databaseNames.count)：\(relative)")
            let sourceLocal = "db_storage/" + relative
            let sourceRelative = account.relativePath.isEmpty ? sourceLocal : account.relativePath + "/" + sourceLocal
            let source = try FileSafety.checkedURL(relativePath: sourceRelative, root: inventory.root)
            let destinationDB = encrypted.appendingPathComponent(relative)
            let outputDB = output.appendingPathComponent(relative)
            try FileSafety.privateDirectory(destinationDB.deletingLastPathComponent())
            try FileSafety.privateDirectory(outputDB.deletingLastPathComponent())
            for suffix in ["", "-wal", "-shm"] {
                let path = sourceRelative + suffix
                let original = URL(fileURLWithPath: source.path + suffix)
                if FileManager.default.fileExists(atPath: original.path) {
                    let checked = try FileSafety.checkedURL(relativePath: path, root: inventory.root)
                    let identity = try FileSafety.identity(checked)
                    try FileManager.default.copyItem(at: checked, to: URL(fileURLWithPath: destinationDB.path + suffix))
                    identities[path] = identity
                    guard try FileSafety.identity(checked) == identity else {
                        throw StorageError.invalid("复制过程中微信索引发生变化，请重新退出微信后重试。")
                    }
                }
            }
            let header = try FileHandle(forReadingFrom: destinationDB)
            let isPlain = try header.read(upToCount: 16) == Data("SQLite format 3\0".utf8)
            try header.close()
            if isPlain {
                // Use SQLite's backup API so an existing WAL is included, never copy only the main DB.
                progress("创建只读索引 \(index + 1)/\(databaseNames.count)：\(relative)")
                try copyPlainDatabase(source: destinationDB, destination: outputDB)
            } else {
                guard let key = matchingKey(keys, relative: relative, allPaths: databaseNames) else {
                    throw StorageError.invalid("密钥文件缺少 \(relative) 的唯一有效密钥。未修改微信数据。")
                }
                let target = ReadOnlyDatabase.literal(outputDB.path)
                let script = """
                .bail on
                PRAGMA key = "x'\(key)'";
                PRAGMA cipher_compatibility = 4;
                SELECT count(*) FROM sqlite_master;
                ATTACH DATABASE \(target) AS plaintext KEY '';
                SELECT sqlcipher_export('plaintext');
                DETACH DATABASE plaintext;
                .quit
                """
                progress("解锁本地索引 \(index + 1)/\(databaseNames.count)：\(relative)")
                do {
                    try runSQLCipher(executable: executable, database: destinationDB, script: script, outputDatabase: outputDB, progress: { bytes in
                        progress("解锁本地索引 \(index + 1)/\(databaseNames.count)：\(relative)，已生成 \(SizeText.format(bytes))")
                    })
                } catch is CancellationError { throw CancellationError() }
                catch { throw StorageError.invalid("解锁 \(relative) 未完成：\(error.localizedDescription)") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputDB.path)
            _ = try ReadOnlyDatabase(outputDB)
            progress("校验只读索引 \(index + 1)/\(databaseNames.count)：\(relative)")
            hashes[relative] = try IndexReader.digest(outputDB)
        }
        for (relative, expected) in identities {
            let url = try FileSafety.checkedURL(relativePath: relative, root: inventory.root)
            guard try FileSafety.identity(url) == expected else {
                throw StorageError.invalid("索引快照期间原始数据库发生变化，已放弃本次快照。")
            }
        }
        guard !processIsRunning() else { throw StorageError.invalid("微信已重新启动，请重新建立索引快照。") }
        let binding = SnapshotBinding(version: 1, accountID: account.id, sourceRoot: inventory.root.path,
            sourceFiles: identities, contentHashes: hashes, createdAt: Date())
        try FileSafety.writePrivate(binding, to: output.appendingPathComponent("source-binding.json"))
        try FileManager.default.removeItem(at: encrypted)
        completed = true
        return output
    }

    static func requiredDatabases(_ root: URL) throws -> [String] {
        var names = ["contact/contact.db", "message/message_resource.db", "hardlink/hardlink.db"]
        let folder = root.appendingPathComponent("message")
        let shards = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: "^message_[0-9]+\\.db$", options: .regularExpression) != nil }
            .map { "message/" + $0.lastPathComponent }.sorted()
        names.append(contentsOf: shards)
        for name in names {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) else {
                throw StorageError.invalid("缺少必需的微信索引：\(name)")
            }
        }
        return names
    }

    static func readKeys(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        guard data.count <= 10 * 1024 * 1024,
              let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StorageError.invalid("密钥文件应为按数据库路径组织的 JSON 对象。")
        }
        let source = dictionary["keys"] as? [String: Any] ?? dictionary
        var result = [String: String]()
        for (name, entry) in source {
            let object = entry as? [String: Any]
            guard var value = entry as? String ?? object?["enc_key"] as? String ?? object?["key"] as? String else { continue }
            if value.hasPrefix("x'"), value.hasSuffix("'") { value = String(value.dropFirst(2).dropLast()) }
            value = value.lowercased()
            guard [64, 96].contains(value.count), value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            result[name.replacingOccurrences(of: "\\", with: "/")] = value
        }
        guard !result.isEmpty else { throw StorageError.invalid("未找到有效的 64 或 96 位十六进制数据库密钥。") }
        return result
    }

    private static func matchingKey(_ keys: [String: String], relative: String, allPaths: [String]) -> String? {
        let exact = keys.filter { $0.key == relative || $0.key == "db_storage/" + relative || $0.key.hasSuffix("/db_storage/" + relative) }
        if exact.count == 1 { return exact.first?.value }
        guard exact.isEmpty else { return nil }
        let basename = (relative as NSString).lastPathComponent
        if allPaths.filter({ ($0 as NSString).lastPathComponent == basename }).count == 1 { return keys[basename] }
        return nil
    }

    static func runSQLCipher(executable: URL, database: URL, script: String, timeout: TimeInterval = 300, outputDatabase: URL? = nil, progress: @Sendable (Int64) -> Void = { _ in }) throws {
        let process = Process(), input = Pipe()
        process.executableURL = executable
        process.arguments = [database.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["SQLITE_HISTORY"] = "/dev/null"
        process.environment = environment
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let started = ProcessInfo.processInfo.systemUptime
        var stoppingAt: TimeInterval?, cancelled = false
        var lastActivity = started, lastReport = started, previousBytes: Int64 = -1
        while process.isRunning {
            let now = ProcessInfo.processInfo.systemUptime
            if let outputDatabase, now - lastReport >= min(2, max(0.05, timeout / 4)) {
                var metadata = stat()
                let bytes = stat(outputDatabase.path, &metadata) == 0 ? Int64(metadata.st_size) : 0
                if bytes > previousBytes { lastActivity = now; previousBytes = bytes }
                progress(bytes); lastReport = now
            }
            if Task.isCancelled || now - lastActivity > timeout || now - started > max(3600, timeout) {
                if stoppingAt == nil {
                    cancelled = Task.isCancelled
                    process.terminate(); stoppingAt = now
                } else if now - stoppingAt! > 15 { kill(process.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        if cancelled { throw CancellationError() }
        if stoppingAt != nil { throw StorageError.invalid("索引解锁长时间无输出进展或超出时限，已停止本工具启动的 SQLCipher。请检查当前数据库状态后重试。") }
        guard process.terminationStatus == 0 else {
            throw StorageError.invalid("索引解锁失败：密钥、SQLCipher 参数或数据库快照不匹配。未修改微信数据。")
        }
    }
}
