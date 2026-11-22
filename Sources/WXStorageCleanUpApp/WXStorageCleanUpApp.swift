import SwiftUI
import WXStorageCleanUpCore

@main struct WXStorageCleanUpApp: App {
    @StateObject private var model = AppModel()
    init() {
        if let flag = CommandLine.arguments.firstIndex(of: "--layout-check"), CommandLine.arguments.count > flag + 1 {
            do {
                try LayoutPreview.run(output: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                exit(0)
            } catch { fputs("布局检查失败：\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--connect-auto"), CommandLine.arguments.count > flag + 1 {
            do {
                let root = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
                let inventory = try Scanner.scan(root: root)
                let requestedIndex = CommandLine.arguments.firstIndex(of: "--account-index")
                let index = requestedIndex.flatMap { CommandLine.arguments.count > $0 + 1 ? Int(CommandLine.arguments[$0 + 1]) : nil }
                guard inventory.accounts.count == 1 || index != nil else { throw StorageError.invalid("发现多个账号，请通过 --account-index 明确选择账号。") }
                guard let account = inventory.accounts.enumerated().first(where: { $0.offset == (index ?? 0) })?.element else {
                    throw StorageError.invalid("没有找到所选账号。")
                }
                let result = try AutomaticConnection().connect(account: account, inventory: inventory) { progress in
                    let item: [String: Any] = ["phase": progress.phase, "verified": progress.verified, "total": progress.total]
                    if let data = try? JSONSerialization.data(withJSONObject: item), let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
                }
                let output: [String: Any] = ["connected": true, "conversations": result.index.conversations.count,
                    "messages": result.index.messages.count, "reusedKeys": result.reusedKeys,
                    "resolvedMessages": result.index.messages.filter { !$0.filePaths.isEmpty }.count,
                    "resolvedFiles": Set(result.index.messages.flatMap(\.filePaths)).count]
                print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
                exit(0)
            } catch { fputs("自动连接未完成：\(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--scan"), CommandLine.arguments.count > flag + 1 {
            do {
                let result = try Scanner.scan(root: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                let output: [String: Any] = ["files": result.files.count, "accounts": result.accounts.count,
                    "logicalBytes": result.logicalBytes, "allocatedEstimateBytes": result.allocatedBytes,
                    "complete": result.complete, "warnings": result.warnings.count, "warningMessages": result.warnings,
                    "skippedLinks": result.skippedLinks, "accountsBlockedByLinks": result.blockedAccountIDs.count]
                print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
                exit(0)
            } catch { fputs("扫描失败：\(error.localizedDescription)\n", stderr); exit(1) }
        }
        // Keep only the snapshots saved connections use; earlier versions left one behind per connection.
        Task.detached(priority: .utility) { AccountConnectionStore().pruneUnusedSnapshots() }
    }
    var body: some Scene {
        WindowGroup("微空间") {
            MainView().environmentObject(model).frame(minWidth: 1080, minHeight: 700)
                .tint(Color.accentGreen)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出微空间") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q").disabled(model.busy)
            }
            CommandGroup(replacing: .newItem) {
                Button("选择微信数据目录…") { model.pickRoot() }.keyboardShortcut("o").disabled(model.busy)
                Button("连接聊天索引…") { model.showingConnection = true }
                    .disabled(model.inventory?.accounts.isEmpty != false || model.busy)
                Button("重新扫描") { model.refresh() }.keyboardShortcut("r").disabled(model.busy || model.inventory == nil)
                Button("导出空间分析…") { model.exportAnalysis() }.disabled(model.busy || model.analysis == nil)
            }
        }
    }
}

extension Color {
    static let accentGreen = Color(red: 0.09, green: 0.43, blue: 0.35)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
}
