import Foundation
import AppKit
import Darwin

public struct AutomaticConnectionProgress: Sendable {
    public let phase: String
    public let verified: Int
    public let total: Int
}

public struct AutomaticConnectionResult: Sendable {
    public let inventory: Inventory
    public let index: AccountIndex
    public let reusedKeys: Bool
}

public struct AutomaticConnection: Sendable {
    public let store: AccountConnectionStore
    public let workingDirectory: URL
    public init(store: AccountConnectionStore = AccountConnectionStore(),
                workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/WeChatStorage/KeyCapture")) {
        self.store = store; self.workingDirectory = workingDirectory
    }
    public static var helperURL: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("key_capture.py")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/key_capture.py")
        return [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    public static func installedApplication() -> URL? {
        let candidates = [URL(fileURLWithPath: "/Applications/WeChat.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/WeChat.app"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tencent.xinWeChat")]
        return candidates.compactMap { $0 }.first { url in
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == "com.tencent.xinWeChat" else { return false }
            return !url.path.contains("/WeChatStorage/KeyCapture/")
        }
    }

    public func connect(account: Account, inventory: Inventory,
                        progress: @escaping @Sendable (AutomaticConnectionProgress) -> Void) throws -> AutomaticConnectionResult {
        #if !arch(arm64)
        throw StorageError.invalid("自动取钥目前支持 Apple Silicon 原生运行。其他架构仍可手动导入索引。")
        #else
        guard let helper = Self.helperURL, let application = Self.installedApplication() else {
            throw StorageError.invalid("未找到原版微信应用或本地连接组件。")
        }
        guard SnapshotService.sqlcipherURL() != nil else { throw StorageError.invalid("缺少 SQLCipher 连接组件，请重新构建完整应用包。") }
        let session = workingDirectory.appendingPathComponent(UUID().uuidString)
        try FileSafety.privateDirectory(session)
        let selectedStorage = inventory.root.appendingPathComponent(account.relativePath).appendingPathComponent("db_storage")
        let names = try SnapshotService.requiredDatabases(selectedStorage)
        let namespace = AccountConnectionStore.namespace(root: inventory.root, accountID: account.id)
        let request = session.appendingPathComponent("request.json")
        try FileSafety.writePrivate(CaptureRequest(version: 1, account: namespace, databases: names), to: request)
        let keys = store.keyFile(root: inventory.root, accountID: account.id)
        try FileSafety.privateDirectory(keys.deletingLastPathComponent())
        let baseArguments = [helper.path, "--db-root", selectedStorage.path, "--request", request.path, "--keys", keys.path]
        var keepSession = false
        defer { if !keepSession { try? FileManager.default.removeItem(at: session) } }
        progress(.init(phase: "正在检查所选账号的本地连接信息…", verified: 0, total: names.count))
        let readiness = try LocalCommand.run("/usr/bin/python3", baseArguments + ["--verify-only"])
        guard readiness.status == 0 || readiness.status == 3 else {
            throw StorageError.invalid("该账号的本地连接缓存无法验证，请忘记此账号连接后重试。")
        }
        let reused = readiness.status == 0
        if !reused {
            let pythonPathBytes = try LocalCommand.require("/usr/bin/xcrun", ["lldb", "-P"])
            guard let pythonPath = String(data: pythonPathBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !pythonPath.isEmpty else {
                throw StorageError.invalid("请先安装 Xcode 或 Command Line Tools，自动连接需要系统 LLDB。")
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = pythonPath
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PYTHONNOUSERSITE"] = "1"
            let check = try LocalCommand.run("/usr/bin/python3", ["-c", "import lldb"], environment: environment)
            guard check.status == 0 else { throw StorageError.invalid("系统 Python 无法加载 LLDB，请检查 Xcode 的开发工具安装。") }
            try Self.quitInstalledApplication(application)
            progress(.init(phase: "正在准备临时微信连接窗口…", verified: 0, total: names.count))
            let signatureFile = application.appendingPathComponent("Contents/_CodeSignature/CodeResources")
            let originalSignature = try IndexReader.digest(signatureFile)
            let originalInfo = NSDictionary(contentsOf: application.appendingPathComponent("Contents/Info.plist"))
            let executableName = originalInfo?["CFBundleExecutable"] as? String ?? "WeChat"
            guard !executableName.contains("/"), executableName != ".." else { throw StorageError.invalid("微信程序入口无效。") }
            let originalExecutable = application.appendingPathComponent("Contents/MacOS/" + executableName)
            let originalExecutableHash = try IndexReader.digest(originalExecutable)
            _ = try LocalCommand.require("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path])
            let shadow = session.appendingPathComponent("WeChat.app")
            _ = try LocalCommand.require("/usr/bin/ditto", [application.path, shadow.path], timeout: 120)
            let entitlements = session.appendingPathComponent("debug.plist")
            let dictionary = ["com.apple.security.get-task-allow": true,
                              "com.apple.security.cs.disable-library-validation": true]
            try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: entitlements, options: .atomic)
            _ = try LocalCommand.require("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--options", "0",
                "--entitlements", entitlements.path, shadow.path], timeout: 120)
            let executable = shadow.appendingPathComponent("Contents/MacOS/" + executableName)
            progress(.init(phase: "请在临时微信窗口进入所选账号，打开联系人及需要整理的聊天以加载索引。", verified: 0, total: names.count))
            var captureError: Error?
            do {
                let capture = try LocalCommand.run("/usr/bin/python3", baseArguments + ["--executable", executable.path, "--timeout", "240"],
                    environment: environment, timeout: 270, event: { event in
                        if ["cache", "progress", "waiting", "launched"].contains(event.event) {
                            progress(.init(phase: "正在连接所选账号；请在临时微信中打开联系人、聊天图片和历史聊天。",
                                verified: event.verified ?? 0, total: event.total ?? names.count))
                        }
                    })
                if capture.status != 0 {
                    let code = capture.events.last(where: { $0.event == "error" })?.code
                    if code == "debug_launch_denied" {
                        throw StorageError.invalid("macOS 拒绝启动调试连接窗口，请检查开发者工具权限；工具不会关闭系统保护。")
                    }
                    throw StorageError.invalid("尚未获取所选账号的全部索引。已验证的部分会保留；下次可继续，请在临时微信切换到所选账号并打开聊天图片。")
                }
            } catch { captureError = error }
            // Always close only our temporary app, including cancellation/error paths.
            if !Self.closeTemporaryApplication(shadow) {
                keepSession = true
                throw StorageError.invalid("临时微信仍在运行。请正常退出该临时窗口后重试；原版微信未被重签名。临时位置：\(shadow.path)")
            }
            _ = try? LocalCommand.require("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                ["-u", shadow.path], ignoreCancellation: true)
            guard try IndexReader.digest(signatureFile) == originalSignature,
                  try IndexReader.digest(originalExecutable) == originalExecutableHash else {
                throw StorageError.invalid("连接期间原版微信发生变化，请重新检查安装版本。")
            }
            if let captureError { throw captureError }
            let verify = try LocalCommand.run("/usr/bin/python3", baseArguments + ["--verify-only"])
            guard verify.status == 0 else { throw StorageError.invalid("账号数据库已变化，已有连接信息不足，请重新自动连接。") }
        } else {
            try Self.quitInstalledApplication(application)
        }
        try Task.checkCancellation()
        progress(.init(phase: "正在刷新账号数据并建立只读索引…", verified: names.count, total: names.count))
        let fresh = try Scanner.scan(root: inventory.root, application: application)
        guard let freshAccount = fresh.accounts.first(where: { $0.id == account.id }) else { throw StorageError.invalid("连接后未找到所选账号，请重新扫描。") }
        let snapshot = try SnapshotService.create(account: freshAccount, inventory: fresh, keyFile: keys, progress: { text in
            progress(.init(phase: text, verified: names.count, total: names.count))
        })
        let index = try IndexReader.load(snapshot: snapshot, account: freshAccount, inventory: fresh)
        try store.save(accountID: account.id, root: fresh.root, snapshot: snapshot)
        progress(.init(phase: "所选账号已连接", verified: names.count, total: names.count))
        return AutomaticConnectionResult(inventory: fresh, index: index, reusedKeys: reused)
        #endif
    }

    private static func quitInstalledApplication(_ application: URL) throws {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.tencent.xinWeChat" || $0.bundleURL?.standardizedFileURL == application.standardizedFileURL
        }
        for app in apps { _ = app.terminate() }
        let end = Date().addingTimeInterval(20)
        while WeChatProcess.isRunning() && Date() < end {
            try Task.checkCancellation(); Thread.sleep(forTimeInterval: 0.2)
        }
        guard !WeChatProcess.isRunning() else { throw StorageError.invalid("微信尚未退出。请保存草稿并用 ⌘Q 正常退出后重试，不会强制结束原版微信。") }
    }

    private static func closeTemporaryApplication(_ application: URL) -> Bool {
        let prefix = application.path + "/"
        for app in NSWorkspace.shared.runningApplications where app.executableURL?.path.hasPrefix(prefix) == true { _ = app.terminate() }
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            guard let pids = temporaryPIDs(prefix) else { return false }
            if pids.isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return temporaryPIDs(prefix)?.isEmpty == true
    }

    private static func temporaryPIDs(_ prefix: String) -> [Int32]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard found > 0, found <= pids.count else { return nil }
        return pids.prefix(Int(found)).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 && String(cString: buffer).hasPrefix(prefix)
        }
    }
}

private struct CaptureRequest: Codable {
    let version: Int
    let account: String
    let databases: [String]
}
