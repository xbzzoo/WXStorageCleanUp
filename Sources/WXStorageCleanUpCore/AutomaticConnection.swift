import Foundation
import AppKit
import Darwin

public struct AutomaticConnectionProgress: Sendable {
    public let phase: String
    public let verified: Int
    public let total: Int
}

enum CaptureFeedback {
    static func phase(_ event: CaptureEvent) -> String {
        let verified = event.verified ?? 0, total = event.total ?? 0
        if total > 0 && verified == total { return "已验证全部密钥，正在结束临时连接并建立索引…" }
        let elapsed = event.elapsed.map { "已等待 \($0) 秒；" } ?? ""
        let remaining = event.remaining.map { "本轮剩余约 \($0) 秒。" } ?? ""
        let pending = event.pending?.prefix(4).joined(separator: "、") ?? ""
        let hint = verified == 0
            ? "请确认登录的是所选账号，并打开联系人、聊天图片和较早的历史消息。"
            : "请继续打开联系人、聊天图片及较早的历史消息，以加载剩余索引。"
        return "\(elapsed)已验证 \(verified)/\(total) 个加密索引。\(remaining)\n\(hint)" +
            (pending.isEmpty ? "" : "\n等待：\(pending)")
    }

    static func failure(_ result: LocalCommandResult) -> String {
        let event = result.events.last { ["error", "incomplete"].contains($0.event) }
        switch event?.code {
        case "debug_launch_denied":
            return "无法启动调试连接窗口。请检查开发者工具权限及 Xcode / Command Line Tools 安装，并核对下方错误信息。"
        case "unsupported_target_architecture":
            return "当前微信程序架构不受支持；自动连接支持 arm64 和 x86_64。"
        case "breakpoint_unavailable":
            return "无法设置本地取钥观察点，当前开发工具或微信版本可能不兼容。请核对开发工具与微信版本后重试。"
        case "breakpoint_unresolved":
            return "当前开发工具未能解析微信取钥观察点，账号尚未连接。请检查 Command Line Tools 是否适配当前 macOS；打开更多聊天无法解决观察点未解析的问题。"
        case "child_resume_failed":
            return "调试组件未能恢复临时微信，账号尚未连接。请检查 Command Line Tools 与当前 macOS 的兼容性后重试。错误代码：child_resume_failed。"
        case "debug_resume_denied":
            return "系统在恢复临时微信时报告权限拒绝。请检查开发者工具权限，并核对系统的开发者工具授权提示。"
        default: break
        }
        let last = result.events.last { $0.verified != nil }
        let verified = last?.verified ?? 0, total = last?.total ?? 0
        let reason: String
        switch event?.code {
        case "child_crashed": reason = "临时微信意外中断。"
        case "child_exited": reason = "临时微信在取齐密钥前退出。"
        case "capture_failed": reason = "本地连接组件发生错误，账号尚未连接。请检查开发工具安装后重试。"
        default: reason = "本轮等待已结束；微信登录成功后，还需要加载所选账号的数据库才能继续连接。"
        }
        let pending = last?.pending?.joined(separator: "、") ?? ""
        let next = verified == 0
            ? "请确认临时微信登录的是所选账号。若打开联系人和历史聊天后仍为 0，可能是微信版本或调试环境不兼容，请核对开发工具与微信版本后重试。"
            : "已验证的密钥保存在本机。可再次自动连接，并打开联系人、聊天图片及较早的历史消息，继续补齐剩余密钥。"
        return "\(reason)已验证 \(verified)/\(total) 个加密索引。\n\(next)" +
            (pending.isEmpty ? "" : "\n尚缺：\(pending)")
    }
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

    // A re-signed, unsandboxed copy otherwise resolves Foundation's home to the
    // login user's home, while the installed app uses its container's Data folder.
    static func dataHome(databaseRoot: URL, fallback: URL = Scanner.defaultRoot) -> URL? {
        var ancestor = databaseRoot.standardizedFileURL
        while ancestor.path != "/" {
            if ancestor.lastPathComponent == "Data",
               ancestor.deletingLastPathComponent().lastPathComponent == "com.tencent.xinWeChat",
               ancestor.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Containers" {
                return ancestor
            }
            ancestor.deleteLastPathComponent()
        }
        // A configured external storage location still uses preferences in the
        // installed app's standard container, when that container exists.
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDirectory) && isDirectory.boolValue ? fallback : nil
    }

    public func connect(account: Account, inventory: Inventory,
                        progress: @escaping @Sendable (AutomaticConnectionProgress) -> Void) throws -> AutomaticConnectionResult {
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
            throw StorageError.invalid("该账号的本地连接缓存无法验证，请确认选择的是当前使用的微信数据目录和账号。")
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
            let homeArguments = Self.dataHome(databaseRoot: selectedStorage).map { ["--data-home", $0.path] } ?? []
            progress(.init(phase: "请在临时微信窗口进入所选账号。登录后还需打开联系人、聊天图片和历史消息以加载索引；取齐后将自动继续。", verified: 0, total: names.count))
            var captureError: Error?
            var verified = readiness.events.last?.verified ?? 0
            var total = readiness.events.last?.total ?? names.count
            do {
                let capture = try LocalCommand.run("/usr/bin/python3", baseArguments + ["--executable", executable.path, "--timeout", "240"] + homeArguments,
                    environment: environment, timeout: 270, event: { event in
                        if ["cache", "progress", "waiting", "launched"].contains(event.event) {
                            progress(.init(phase: CaptureFeedback.phase(event),
                                verified: event.verified ?? 0, total: event.total ?? names.count))
                        }
                    })
                try? store.saveDiagnostic(capture, root: inventory.root, accountID: account.id, application: application)
                verified = capture.events.last(where: { $0.verified != nil })?.verified ?? verified
                total = capture.events.last(where: { $0.total != nil })?.total ?? total
                if capture.status != 0 {
                    throw StorageError.invalid(CaptureFeedback.failure(capture))
                }
            } catch { captureError = error }
            // Always close only our temporary app, including cancellation/error paths.
            progress(.init(phase: "正在退出临时微信，已验证的本地密钥会保留…", verified: verified, total: total))
            let exit = TemporaryApplicationCloser().close(shadow)
            if exit != .closed {
                keepSession = true
                throw StorageError.invalid(exit.failureMessage(application: shadow, captureError: captureError, verified: verified, total: total))
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
        let fresh = try Scanner.scan(root: inventory.root, application: application,
            related: inventory.relatedLocations.map { URL(fileURLWithPath: $0.path) }, progress: { scan in
            progress(.init(phase: "正在刷新账号附件清单：\(scan.count) 个文件…", verified: names.count, total: names.count))
        })
        guard let freshAccount = fresh.accounts.first(where: { $0.id == account.id }) else { throw StorageError.invalid("连接后未找到所选账号，请重新扫描。") }
        let snapshot = try SnapshotService.create(account: freshAccount, inventory: fresh, keyFile: keys,
            destination: store.snapshotDirectory, progress: { text in
            progress(.init(phase: text, verified: names.count, total: names.count))
        })
        // Only the snapshot a saved connection uses is kept; a failed connection leaves none behind.
        var saved = false
        defer { if !saved { store.removeSnapshot(snapshot) } }
        let index = try IndexReader.load(snapshot: snapshot, account: freshAccount, inventory: fresh,
            digestCache: store.digestCacheFile(root: fresh.root, accountID: account.id), progress: { text in
            progress(.init(phase: text, verified: names.count, total: names.count))
        })
        try store.save(accountID: account.id, root: fresh.root, snapshot: snapshot)
        saved = true
        store.pruneUnusedSnapshots()
        progress(.init(phase: "所选账号已连接", verified: names.count, total: names.count))
        return AutomaticConnectionResult(inventory: fresh, index: index, reusedKeys: reused)
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

}

private struct CaptureRequest: Codable {
    let version: Int
    let account: String
    let databases: [String]
}
