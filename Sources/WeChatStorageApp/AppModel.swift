import SwiftUI
import AppKit
import WeChatStorageCore

enum Page: String, CaseIterable, Identifiable {
    case overview = "空间概览", chats = "聊天与消息", unassigned = "未归属附件", history = "操作记录"
    var id: Self { self }
    var icon: String {
        switch self { case .overview: "chart.pie"; case .chats: "bubble.left.and.bubble.right"; case .history: "clock.arrow.circlepath"; case .unassigned: "tray.full" }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var page: Page = .overview
    @Published var inventory: Inventory?
    @Published var indexes: [String: AccountIndex] = [:]
    @Published var analysis: Analysis?
    @Published var selectedAccount = "" {
        didSet {
            guard oldValue != selectedAccount else { return }
            accountSelectionChanged()
        }
    }
    @Published var selectedConversation: String? {
        didSet {
            if oldValue != selectedConversation { checkedMessages = []; messageSearch = "" }
        }
    }
    @Published var checkedConversations = Set<String>()
    @Published var checkedMessages = Set<String>()
    @Published var checkedUnassigned = Set<String>()
    @Published var unassignedSearch = ""
    @Published var unassignedType = "全部"
    @Published var search = ""
    @Published var messageSearch = ""
    @Published var mediaFilter = "全部"
    @Published var beforeDate = Date()
    @Published var useDateFilter = false
    @Published var busy = false
    @Published var status = "选择微信数据目录，开始了解空间去向"
    @Published var progressCount = 0
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var plan: CleanupPlan?
    @Published var cleanupCompletion: CleanupRecord?
    @Published var records: [CleanupRecord] = []
    @Published var showingConnection = false
    @Published var isDemo = false
    @Published var availableBefore: Int64?
    @Published var availableAfter: Int64?
    @Published var connectionStatus: [String: String] = [:]
    @Published var captureVerified = 0
    @Published var captureTotal = 0
    private var job: Task<Void, Never>?
    private let cleanup: CleanupService
    private var root: URL?
    private var scopedURL: URL?
    private let connectionStore = AccountConnectionStore()
    private var switchingScope = false
    private var selectionScope = AccountSelection()

    init(cleanup: CleanupService = CleanupService()) { self.cleanup = cleanup; records = cleanup.records() }
    var appVersion: String {
        let url = URL(fileURLWithPath: "/Applications/WeChat.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "未检测到安装版本" }
        return "微信 " + ((plist["WeChatBundleVersion"] ?? plist["CFBundleShortVersionString"]) as? String ?? "未知版本")
    }
    var visibleConversations: [ConversationUsage] {
        (analysis?.conversations ?? []).filter {
            (selectedAccount.isEmpty || $0.conversation.accountID == selectedAccount) &&
            (search.isEmpty || $0.conversation.name.localizedCaseInsensitiveContains(search) ||
             ($0.conversation.internalID ?? $0.conversation.directoryHash).localizedCaseInsensitiveContains(search))
        }
    }
    var currentConversation: ConversationUsage? {
        analysis?.conversations.first { $0.id == selectedConversation && $0.conversation.accountID == selectedAccount }
    }
    var visibleMessages: [IndexedMessage] {
        (analysis?.messages ?? []).filter { message in
            message.conversationID == currentConversation?.id &&
            (mediaFilter == "全部" || message.kind.rawValue == mediaFilter) &&
            (!useDateFilter || message.date < Calendar.current.startOfDay(for: beforeDate).addingTimeInterval(86400)) &&
            (messageSearch.isEmpty || message.summary.localizedCaseInsensitiveContains(messageSearch) || message.localID.contains(messageSearch) ||
             message.filePaths.contains { $0.localizedCaseInsensitiveContains(messageSearch) })
        }.sorted { $0.timestamp > $1.timestamp }
    }
    var warnings: [String] { (inventory?.warnings ?? []) + indexes.values.flatMap(\.warnings) }
    var accountUnassigned: [StoredFile] {
        (analysis?.unassignedAttachments ?? []).filter { $0.accountID == selectedAccount }
    }
    var visibleUnassigned: [StoredFile] {
        accountUnassigned.filter {
            (unassignedType == "全部" || $0.attachmentKind.rawValue == unassignedType) &&
            (unassignedSearch.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(unassignedSearch))
        }
    }
    var selectedUnassignedBytes: Int64 {
        accountUnassigned.filter { checkedUnassigned.contains($0.id) }.reduce(0) { $0 + $1.identity.bytes }
    }
    var cleanupCompletionMessage: String {
        guard let record = cleanupCompletion else { return "" }
        var message = "本次已移入废纸篓 \(record.trashedCount) 个附件路径，文件数据仍占用磁盘空间。请先在 Finder 核对本次项目，再清空废纸篓中的这些项目，才能回收可释放空间。"
        if record.items.contains(where: { $0.state == "trashed" && $0.expectedIdentity.links > 1 }) {
            message += "\n\n共享文件若仍有其他硬链接，清空后也不会释放这份数据空间。"
        }
        return message
    }
    var canCleanCurrentConversation: Bool { currentConversation?.indexedFilePaths.isEmpty == false && !busy }

    private func clearCleanupSelection() {
        checkedConversations = []; checkedMessages = []; checkedUnassigned = []
        selectionScope.setSelection(conversations: [], messages: [])
        plan = nil
    }

    func accountLabel(_ account: Account) -> String {
        let state = connectionStatus[account.id] ?? (indexes[account.id] == nil ? "未连接" : "已连接")
        return "\(account.id) · \(state)"
    }
    private func accountSelectionChanged() {
        if let inventory, !selectedAccount.isEmpty {
            do { try selectionScope.select(selectedAccount, available: inventory.accounts) }
            catch { errorMessage = error.localizedDescription; return }
        }
        selectedConversation = nil
        checkedMessages = selectionScope.messageIDs; checkedConversations = selectionScope.conversationIDs; plan = nil
        checkedUnassigned = []; unassignedSearch = ""; unassignedType = "全部"
        search = ""; messageSearch = ""; mediaFilter = "全部"; useDateFilter = false
        if let inventory {
            UserDefaults.standard.set(selectedAccount, forKey: AccountConnectionStore.selectionKey(root: inventory.root))
        }
        guard !switchingScope, !busy, !isDemo else { return }
        restoreSelectedConnection()
    }

    private func restoreSelectedConnection() {
        guard let inventory, let account = inventory.accounts.first(where: { $0.id == selectedAccount }) else { return }
        if let loaded = indexes[account.id] {
            let changed = loaded.sourceFiles.contains { path, expected in
                guard let url = try? FileSafety.checkedURL(relativePath: path, root: inventory.root),
                      let current = try? FileSafety.identity(url) else { return true }
                return current != expected
            }
            if !changed { return }
            indexes[account.id] = nil; connectionStatus[account.id] = "需刷新连接"; rebuild()
        }
        guard
              let saved = connectionStore.saved(accountID: account.id, root: inventory.root) else { return }
        work("正在载入所选账号的本地索引…", operation: {
            try IndexReader.load(snapshot: URL(fileURLWithPath: saved.snapshotPath), account: account, inventory: inventory)
        }, success: { [self] index in
            indexes[index.accountID] = index; connectionStatus[index.accountID] = "已连接"
            rebuild(); status = "已切换到账号 \(account.id)"
        }, failure: { [weak self] _ in
            self?.connectionStatus[account.id] = "需刷新连接"
            self?.errorMessage = nil
            self?.status = "所选账号的索引已更新，点击自动连接可刷新"
        })
    }

    func automaticallyConnect() {
        guard !busy, !isDemo, let inventory,
              let account = inventory.accounts.first(where: { $0.id == selectedAccount }) else { return }
        let connector = AutomaticConnection(store: connectionStore)
        captureVerified = 0; captureTotal = 0; connectionStatus[account.id] = "连接中"
        checkedConversations = []; checkedMessages = []; plan = nil
        work("正在自动连接所选账号…", operation: { [self] in
            try connector.connect(account: account, inventory: inventory) { progress in
                Task { @MainActor in
                    guard self.busy, self.selectedAccount == account.id, self.connectionStatus[account.id] == "连接中" else { return }
                    self.status = progress.phase; self.captureVerified = progress.verified; self.captureTotal = progress.total
                }
            }
        }, success: { [self] result in
            self.inventory = result.inventory; indexes[account.id] = result.index; connectionStatus[account.id] = "已连接"
            rebuild(); showingConnection = false; page = .chats
            selectedConversation = analysis?.conversations.first(where: { $0.conversation.accountID == account.id })?.id
            status = result.reusedKeys ? "已复用本机保存的连接信息" : "已自动获取并验证所选账号索引"
            notice = "账号 \(account.id) 已连接。微信保持退出，便于你核对附件并预览清理。"
        }, failure: { [weak self] error in
            self?.connectionStatus[account.id] = error is CancellationError ? "已取消" : "未完成"
        })
    }

    func forgetSelectedConnection() {
        guard let inventory, !busy else { return }
        do {
            try connectionStore.forget(accountID: selectedAccount, root: inventory.root)
            indexes[selectedAccount] = nil; connectionStatus[selectedAccount] = "未连接"
            checkedMessages = []; checkedConversations = []; selectedConversation = nil; search = ""; messageSearch = ""; plan = nil; rebuild()
            notice = "已忘记所选账号的自动连接密钥和连接记录，其他账号保留。"
        } catch { errorMessage = error.localizedDescription }
    }

    func pickRoot() {
        let panel = NSOpenPanel()
        panel.title = "选择微信 Data、xwechat_files 或账号目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        panel.directoryURL = Scanner.defaultRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url, demo: false)
    }
    func scanDefault() { scan(Scanner.defaultRoot, demo: false) }
    func refresh() { if let root { scan(root, demo: isDemo, preserveIndexes: true) } }
    func cancel() { job?.cancel() }

    func scan(_ url: URL, demo: Bool, preserveIndexes: Bool = false) {
        guard !busy else { return }
        scopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        root = url; isDemo = demo; if !preserveIndexes { notice = nil }; progressCount = 0
        if !preserveIndexes {
            indexes = [:]; connectionStatus = [:]; selectionScope = AccountSelection()
            clearCleanupSelection(); selectedConversation = nil
        }
        let app = !demo && FileManager.default.fileExists(atPath: "/Applications/WeChat.app") ? URL(fileURLWithPath: "/Applications/WeChat.app") : nil
        work("正在扫描文件大小…", operation: { [self] in
            try Scanner.scan(root: url, application: app) { progress in
                Task { @MainActor in self.progressCount = progress.count; self.status = "已扫描 \(progress.count) 个文件 · \(SizeText.format(progress.bytes))" }
            }
        }, success: { [self] result in
            inventory = result
            switchingScope = true
            if !preserveIndexes {
                let saved = UserDefaults.standard.string(forKey: AccountConnectionStore.selectionKey(root: result.root))
                selectedAccount = result.accounts.contains(where: { $0.id == saved }) ? (saved ?? "") : (result.accounts.first?.id ?? "")
            } else if !result.accounts.contains(where: { $0.id == selectedAccount }) { selectedAccount = result.accounts.first?.id ?? "" }
            switchingScope = false
            rebuild(); status = result.complete ? "扫描完成" : "扫描完成，部分范围未读取"
            if !preserveIndexes { page = .overview }
            if !demo { restoreSelectedConnection() }
        })
    }

    func loadDemo() {
        guard !busy else { return }
        work("正在创建独立的演示数据…", operation: {
            let demo = try DemoFactory.createMultiple(includeUnassigned: true)
            let inventory = try Scanner.scan(root: demo.root)
            let indexes = try inventory.accounts.map { account in
                try IndexReader.load(snapshot: demo.snapshots[account.id]!, account: account, inventory: inventory)
            }
            return (demo, inventory, indexes)
        }, success: { [self] demo, result, loaded in
            root = demo.root; isDemo = true; inventory = result
            indexes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.accountID, $0) })
            connectionStatus = Dictionary(uniqueKeysWithValues: loaded.map { ($0.accountID, "演示已连接") })
            selectedAccount = result.accounts.first?.id ?? ""; checkedConversations = []; checkedMessages = []
            rebuild(); selectedConversation = analysis?.conversations.first(where: { $0.conversation.accountID == selectedAccount })?.id
            page = .chats; status = "演示数据已就绪，文件大小均来自实际生成的文件"
            notice = "演示模式：所有清理和恢复只操作独立演示目录，不访问真实微信资料。"
        })
    }

    func importSnapshot() {
        guard let inventory, let account = inventory.accounts.first(where: { $0.id == selectedAccount }) else { return }
        let panel = NSOpenPanel(); panel.title = "选择已解密的 db_storage 目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        work("正在读取会话与消息索引…", operation: {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try IndexReader.load(snapshot: url, account: account, inventory: inventory)
        }, success: { [self] index in
            indexes[index.accountID] = index; connectionStatus[index.accountID] = index.trustedBinding ? "已连接" : "仅预览"; rebuild(); showingConnection = false
            selectedConversation = analysis?.conversations.first(where: { $0.conversation.accountID == selectedAccount })?.id
            page = .chats; status = index.trustedBinding ? "已连接当前账号索引" : "已导入索引预览，清理已锁定"
        })
    }

    func importKeys() {
        guard let inventory, let account = inventory.accounts.first(where: { $0.id == selectedAccount }) else { return }
        let panel = NSOpenPanel(); panel.title = "选择当前账号的本地数据库密钥 JSON"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        work("正在创建只读索引快照…", operation: { [self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let snapshot = try SnapshotService.create(account: account, inventory: inventory, keyFile: url, progress: { text in
                Task { @MainActor in self.status = text }
            })
            return try IndexReader.load(snapshot: snapshot, account: account, inventory: inventory)
        }, success: { [self] index in
            indexes[index.accountID] = index; connectionStatus[index.accountID] = "已连接"; rebuild(); showingConnection = false; page = .chats
            selectedConversation = analysis?.conversations.first(where: { $0.conversation.accountID == selectedAccount })?.id
            status = "本地索引已连接，可按聊天和消息预览清理"
        })
    }

    func preview(conversations: Bool) {
        guard let analysis else { return }
        do {
            try selectionScope.select(selectedAccount, available: analysis.inventory.accounts)
            selectionScope.setSelection(conversations: conversations ? checkedConversations : [],
                messages: conversations ? [] : checkedMessages)
            plan = try CleanupPlanner.plan(analysis: analysis,
                conversationIDs: selectionScope.conversationIDs,
                messageIDs: selectionScope.messageIDs, allowedAccountID: selectedAccount)
        } catch { errorMessage = error.localizedDescription }
    }
    func previewCurrentConversation() {
        guard let analysis, let conversation = currentConversation else { return }
        do {
            plan = try CleanupPlanner.plan(analysis: analysis, conversationIDs: [conversation.id], allowedAccountID: selectedAccount)
        } catch { errorMessage = error.localizedDescription }
    }
    func previewUnassigned() {
        guard let analysis else { return }
        do {
            plan = try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: checkedUnassigned, accountID: selectedAccount)
        } catch { errorMessage = error.localizedDescription }
    }
    func executePlan(trash: @escaping @Sendable (URL) throws -> URL = { try CleanupService.systemTrash($0) }) {
        guard let plan else { return }
        self.plan = nil
        let demo = isDemo, service = cleanup
        availableBefore = availableSpace(plan.root)
        work("正在将选中的附件移入废纸篓…", operation: {
            try service.execute(plan, processIsRunning: { demo ? false : WeChatProcess.isRunning() }, trash: trash)
        }, success: { [self] record in
            records = cleanup.records(); clearCleanupSelection()
            availableAfter = availableSpace(plan.root)
            notice = "已移入废纸篓 \(record.trashedCount) 个附件路径。需在 Finder 清空相应项目；文件仍有其他硬链接时，数据空间继续被占用。"
            if record.trashedCount > 0 { cleanupCompletion = record }
            status = "本次操作已记录，可继续选择附件；结果可在操作记录查看"
            refresh()
        })
    }
    func restore(_ record: CleanupRecord) {
        let service = cleanup
        let isDemoRecord = record.root.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WeChatStorage/Demo/").path)
        work("正在恢复可恢复的附件…", operation: {
            try service.restore(record, processIsRunning: { isDemoRecord ? false : WeChatProcess.isRunning() })
        }, success: { [self] result in
            records = cleanup.records(); notice = "已恢复 \(result.restoredCount) 个附件；冲突和不可恢复项目请查看记录。"
            status = "恢复结果已记录"; refresh()
        })
    }
    func reveal(_ relativePath: String) {
        guard let inventory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([inventory.root.appendingPathComponent(relativePath)])
    }
    func revealTrash(_ record: CleanupRecord) {
        let urls = record.items.filter { $0.state == "trashed" }.compactMap { $0.trashURL }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func exportAnalysis() {
        guard let analysis else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "微信空间分析.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report: [String: Any] = [
                "generatedAt": ISO8601DateFormatter().string(from: Date()), "scope": analysis.inventory.root.path,
                "complete": analysis.inventory.complete, "dataLogicalBytes": analysis.inventory.logicalBytes,
                "dataAllocatedEstimateBytes": analysis.inventory.allocatedBytes,
                "unattributedLogicalBytes": analysis.unattributedBytes,
                "unassignedAttachments": analysis.unassignedAttachments.map { file -> [String: Any] in
                    ["path": file.relativePath, "account": file.accountID ?? "", "logicalBytes": file.identity.bytes,
                     "allocatedEstimateBytes": file.allocatedBytes]
                },
                "conversations": analysis.conversations.map { usage -> [String: Any] in
                    ["name": usage.conversation.name, "account": usage.conversation.accountID,
                     "internalID": usage.conversation.internalID ?? "", "attachmentLogicalBytes": usage.logicalBytes,
                     "exclusiveAllocatedEstimateBytes": usage.allocatedBytes, "sharedAllocatedEstimateBytes": usage.sharedBytes,
                     "indexedFiles": usage.indexedFilePaths.count, "directoryFiles": usage.filePaths.count]
                }
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { errorMessage = error.localizedDescription }
    }
    func eraseSnapshots() {
        do {
            let url = SnapshotService.defaultDirectory
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            indexes = [:]; connectionStatus = connectionStatus.mapValues { _ in "需刷新连接" }
            rebuild(); notice = "已清除本工具创建的明文索引快照，微信原始数据未改动。"
        } catch { errorMessage = error.localizedDescription }
    }
    private func rebuild() {
        if let inventory {
            analysis = Analysis(inventory: inventory, indexes: Array(indexes.values))
            checkedConversations.formIntersection(Set(visibleConversations.map(\.id)))
            checkedMessages.formIntersection(Set(analysis?.messages.map(\.id) ?? []))
            checkedUnassigned.formIntersection(Set(accountUnassigned.map(\.id)))
            if selectedConversation != nil, currentConversation == nil { selectedConversation = nil }
        }
    }
    private func availableSpace(_ root: URL) -> Int64? {
        (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }
    private func work<T: Sendable>(_ label: String, operation: @escaping @Sendable () throws -> T,
                                  success: @escaping (T) -> Void, failure: ((Error) -> Void)? = nil) {
        guard !busy else { return }
        busy = true; status = label; errorMessage = nil
        job = Task {
            let child = Task.detached(priority: .userInitiated, operation: operation)
            do {
                let value = try await withTaskCancellationHandler(operation: { try await child.value }, onCancel: { child.cancel() })
                busy = false; success(value)
            } catch is CancellationError { busy = false; status = "任务已取消，已完成的文件操作保留在记录中"; records = cleanup.records(); failure?(CancellationError()) }
            catch { busy = false; status = "操作未完成"; errorMessage = error.localizedDescription; records = cleanup.records(); failure?(error) }
        }
    }
}
