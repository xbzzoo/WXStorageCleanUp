import SwiftUI
import AppKit
import WXStorageCleanUpCore

enum Page: String, CaseIterable, Identifiable {
    case overview = "空间概览", chats = "聊天与消息", unassigned = "其他文件", history = "操作记录"
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
            if oldValue != selectedConversation { checkedMessages = []; messageSearch = ""; refreshVisibleMessages() }
        }
    }
    @Published var checkedConversations = Set<String>()
    @Published var checkedMessages = Set<String>()
    @Published var checkedUnassigned = Set<String>()
    @Published var unassignedSearch = "" { didSet { refreshUnassigned() } }
    @Published var unassignedType = "全部" { didSet { refreshUnassigned() } }
    @Published var search = ""
    @Published var messageSearch = "" { didSet { if oldValue != messageSearch { refreshVisibleMessages() } } }
    @Published var mediaFilter = "全部" { didSet { if oldValue != mediaFilter { refreshVisibleMessages() } } }
    @Published var beforeDate = Date() { didSet { if oldValue != beforeDate { refreshVisibleMessages() } } }
    @Published var useDateFilter = false { didSet { if oldValue != useDateFilter { refreshVisibleMessages() } } }
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
    @Published private(set) var analysisLoading = false
    @Published private(set) var filteredMessageCache: [IndexedMessage] = []
    private var removedChatIDs = Set<String>()
    private var conversationByID: [String: ConversationUsage] = [:]
    private var messagesByConversation: [String: [IndexedMessage]] = [:]
    private var filterGeneration = 0
    private var rebuildGeneration = 0
    private var unassignedGeneration = 0
    private var unassignedByAccount: [String: [StoredFile]] = [:]
    private var unassignedByPath: [String: StoredFile] = [:]
    private var unassignedTotals: [String: Int64] = [:]
    @Published private(set) var filteredUnassigned: [StoredFile] = []
    @Published private(set) var unassignedLoading = false
    @Published var messageLimit = 200
    @Published var unassignedLimit = 200
    @Published var includeSharedAttachments = false
    private var messageTask: Task<Void, Never>?
    private var unassignedTask: Task<Void, Never>?
    private var job: Task<Void, Never>?
    private let cleanup: CleanupService
    private var root: URL?
    private var scopedURL: URL?
    private let connectionStore: AccountConnectionStore
    private var switchingScope = false
    private var promptConnectionAfterScan = false
    private var selectionScope = AccountSelection()

    init(cleanup: CleanupService = CleanupService(), connectionStore: AccountConnectionStore = AccountConnectionStore()) {
        self.cleanup = cleanup; self.connectionStore = connectionStore; records = cleanup.records()
    }
    var appVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "开发版" }
        return "版本 " + version
    }

    var visibleConversations: [ConversationUsage] {
        let all = (analysis?.conversations ?? []).filter { !removedChatIDs.contains($0.id) && (selectedAccount.isEmpty || $0.conversation.accountID == selectedAccount) }
        guard !search.isEmpty else { return all }
        return all.filter {
            (selectedAccount.isEmpty || $0.conversation.accountID == selectedAccount) &&
            (search.isEmpty || $0.conversation.name.localizedCaseInsensitiveContains(search) ||
             ($0.conversation.internalID ?? $0.conversation.directoryHash).localizedCaseInsensitiveContains(search))
        }
    }
    var currentConversation: ConversationUsage? {
        guard let selectedConversation, !removedChatIDs.contains(selectedConversation), let usage = (isDemo ? analysis?.conversations.first { $0.id == selectedConversation } : conversationByID[selectedConversation]),
              usage.conversation.accountID == selectedAccount else { return nil }
        return usage
    }
    var visibleMessages: [IndexedMessage] {
        Array(filteredMessageCache.prefix(messageLimit))
    }
    func messageBytes(_ message: IndexedMessage) -> Int64 { analysis?.bytes(for: message) ?? 0 }
    var warnings: [String] { (inventory?.warnings ?? []) + indexes.values.flatMap(\.warnings) }
    var accountUnassigned: [StoredFile] { (isDemo ? analysis?.unassignedAttachments.filter { $0.accountID == selectedAccount } : unassignedByAccount[selectedAccount]) ?? [] }
    var accountUnassignedBytes: Int64 { unassignedTotals[selectedAccount] ?? 0 }
    var visibleUnassigned: [StoredFile] {
        if isDemo { return Array(accountUnassigned.filter { (unassignedType == "全部" || $0.attachmentKind.rawValue == unassignedType) && (unassignedSearch.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(unassignedSearch)) }.prefix(unassignedLimit)) }
        return Array(filteredUnassigned.prefix(unassignedLimit))
    }
    var selectedUnassignedBytes: Int64 {
        checkedUnassigned.reduce(0) { $0 + (unassignedByPath[$1]?.identity.bytes ?? 0) }
    }
    func selectAllUnassigned() { checkedUnassigned.formUnion(filteredUnassigned.map(\.id)) }
    var cleanupCompletionMessage: String {
        guard let record = cleanupCompletion else { return "" }
        var message = "本次已移入废纸篓 \(record.trashedCount) 个附件路径，文件数据仍占用磁盘空间。请先在 Finder 核对本次项目，再清空废纸篓中的这些项目，才能回收可释放空间。"
        if record.items.contains(where: { $0.state == "trashed" && $0.isDirectory != true && $0.expectedIdentity.links > 1 }) {
            message += "\n\n共享文件若仍有其他硬链接，清空后也不会释放这份数据空间。"
        }
        return message
    }
    var canCleanCurrentConversation: Bool { currentConversation?.filePaths.isEmpty == false && !busy && !analysisLoading }

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
        includeSharedAttachments = false
        refreshUnassigned()
        refreshVisibleMessages()
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
            self?.presentScanConnectionIfNeeded()
        })
    }

    private func presentScanConnectionIfNeeded() {
        guard promptConnectionAfterScan, !busy else { return }
        promptConnectionAfterScan = false
        guard !isDemo, !selectedAccount.isEmpty, indexes[selectedAccount] == nil else { return }
        notice = "扫描完成。请先连接聊天，以显示聊天名称、消息和对应附件。"
        showingConnection = true
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
            status = "正在整理聊天与附件统计…"
            notice = "账号 \(account.id) 已连接。微信保持退出，便于你核对附件并清理。"
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

    func revealSelectedKeys() {
        guard !busy else { return }
        guard let inventory, !selectedAccount.isEmpty else { return }
        let file = connectionStore.keyFile(root: inventory.root, accountID: selectedAccount)
        guard FileManager.default.fileExists(atPath: file.path) else {
            errorMessage = "所选账号尚无本地密钥文件。请先尝试自动连接；手机确认登录只完成了登录步骤，仍需加载所选账号的数据库。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func copyConnectionDiagnostics() {
        guard !busy else { return }
        guard let inventory, !selectedAccount.isEmpty else { return }
        do {
            let text = try connectionStore.diagnosticText(root: inventory.root, accountID: selectedAccount)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notice = "连接诊断已复制，包含版本、验证数量及调试状态，不含密钥或聊天内容。"
        } catch { errorMessage = error.localizedDescription }
    }

    func openConnectionGuide() {
        guard !busy else { return }
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("connection-guide.md")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/connection-guide.md")
        if let file = [bundled, source].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.open(file)
        } else { errorMessage = "未找到随包连接指引，请查看源码 docs/connection-guide.md。" }
    }

    func pickRoot() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "选择微信 Data、xwechat_files 或账号目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        panel.directoryURL = Scanner.defaultRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url, demo: false)
    }
    func scanDefault() { scan(Scanner.defaultRoot, demo: false) }
    func refresh() { if let root { scan(root, demo: isDemo, preserveIndexes: true) } }
    func cancel() { guard !busy else { return }; job?.cancel() }

    func scan(_ url: URL, demo: Bool, preserveIndexes: Bool = false) {
        guard !busy else { return }
        promptConnectionAfterScan = false
        scopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        removedChatIDs = []
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
            promptConnectionAfterScan = !demo && !result.accounts.isEmpty
            rebuild(); status = result.complete ? "扫描完成" : "扫描完成，部分范围未读取"
            if !preserveIndexes { page = .overview }
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
        guard !busy else { return }
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
        guard !busy else { return }
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
            status = "本地索引已连接，可按聊天和消息清理"
        })
    }

    func preview(conversations: Bool) {
        guard let analysis, !analysisLoading else { return }
        let chats = conversations ? checkedConversations : []
        let messages = conversations ? [] : checkedMessages
        let account = selectedAccount, shared = includeSharedAttachments
        work("正在生成清理预览…", operation: {
            try CleanupPlanner.plan(analysis: analysis, conversationIDs: chats, messageIDs: messages,
                                    allowedAccountID: account, includeOtherReferences: shared)
        }, success: { [self] value in plan = value })
    }
    func previewCurrentConversation() {
        guard let analysis, let conversation = currentConversation, !analysisLoading else { return }
        let account = selectedAccount
        work("正在核对该聊天的全部附件…", operation: {
            try CleanupPlanner.planConversation(analysis: analysis, conversationID: conversation.id, accountID: account)
        }, success: { [self] value in plan = value })
    }
    func openCurrentConversationFolder() {
        guard !busy else { return }
        guard let inventory, let chat = currentConversation,
              let account = inventory.accounts.first(where: { $0.id == selectedAccount }) else { return }
        let base = account.relativePath.isEmpty ? "msg" : account.relativePath + "/msg"
        let folder = base + "/attach/" + chat.conversation.directoryHash
        do {
            let relative = Scanner.isHash(chat.conversation.directoryHash) && FileManager.default.fileExists(atPath: inventory.root.appendingPathComponent(folder).path) ? folder : base
            let url = try FileSafety.checkedURL(relativePath: relative, root: inventory.root)
            NSWorkspace.shared.open(url)
        } catch { errorMessage = error.localizedDescription }
    }
    func previewUnassigned() {
        guard let analysis, !analysisLoading else { return }
        let paths = checkedUnassigned, account = selectedAccount
        work("正在核对附件并生成预览…", operation: {
            try CleanupPlanner.planUnassigned(analysis: analysis, relativePaths: paths, accountID: account)
        }, success: { [self] value in plan = value })
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
            if plan.scope == .conversationAttachments, let inventory {
                let removed = record.items.filter { $0.state == "trashed" }
                let roots = Set(removed.map(\.sourceRelativePath))
                let folders = removed.filter { $0.isDirectory == true }.map { $0.sourceRelativePath + "/" }
                self.inventory = inventory.removing(paths: roots, directoryPrefixes: folders)
                if record.state == "completed", let chatID = plan.conversationID { removedChatIDs.insert(chatID); selectedConversation = nil }
                rebuild()
            } else { refresh() }
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
        guard !busy else { return }
        guard let inventory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([inventory.root.appendingPathComponent(relativePath)])
    }
    func revealTrash(_ record: CleanupRecord) {
        let urls = record.items.filter { $0.state == "trashed" }.compactMap { $0.trashURL }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
    func exportAnalysis() {
        guard !busy else { return }
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
        rebuildGeneration += 1
        let generation = rebuildGeneration
        guard let inventory else { analysis = nil; return }
        analysisLoading = true
        busy = true
        filterGeneration += 1
        messageTask?.cancel()
        let loadedIndexes = Array(indexes.values)
        Task.detached(priority: .userInitiated) { [self] in
            let result = Analysis(inventory: inventory, indexes: loadedIndexes)
            let conversations = Dictionary(uniqueKeysWithValues: result.conversations.map { ($0.id, $0) })
            var byConversation = Dictionary(grouping: result.messages, by: \.conversationID)
            for id in Array(byConversation.keys) { byConversation[id]?.sort { $0.timestamp > $1.timestamp } }
            let unassigned = Dictionary(grouping: result.unassignedAttachments, by: { $0.accountID ?? "" })
            let paths = Dictionary(uniqueKeysWithValues: result.unassignedAttachments.map { ($0.id, $0) })
            let totals = unassigned.mapValues { $0.reduce(Int64(0)) { $0 + $1.identity.bytes } }
            let groupedMessages = byConversation
            let validChats = Set(conversations.keys)
            let validMessages = Set(result.messages.map(\.id))
            let validFiles = Set(paths.keys)
            await MainActor.run {
                guard self.rebuildGeneration == generation else { return }
                self.analysis = result
                self.conversationByID = conversations
                self.messagesByConversation = groupedMessages
                self.unassignedByAccount = unassigned
                self.unassignedByPath = paths
                self.unassignedTotals = totals
                self.checkedConversations.formIntersection(validChats)
                self.checkedMessages.formIntersection(validMessages)
                self.checkedUnassigned.formIntersection(validFiles)
                self.analysisLoading = false
                self.busy = false
                if self.status == "正在整理聊天与附件统计…" { self.status = "所选账号已连接，聊天数据已就绪" }
                if self.currentConversation == nil {
                    self.selectedConversation = result.conversations.first { $0.conversation.accountID == self.selectedAccount && !self.removedChatIDs.contains($0.id) }?.id
                }
                self.refreshVisibleMessages()
                self.refreshUnassigned()
                if !self.isDemo { self.restoreSelectedConnection() }
                self.presentScanConnectionIfNeeded()
            }
        }
    }

    private func refreshUnassigned() {
        unassignedTask?.cancel()
        unassignedGeneration += 1
        let generation = unassignedGeneration
        let source = accountUnassigned, query = unassignedSearch, kind = unassignedType
        unassignedLimit = 200
        filteredUnassigned = []
        unassignedLoading = true
        unassignedTask = Task { [weak self] in
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                source.filter { (kind == "全部" || $0.attachmentKind.rawValue == kind) &&
                    (query.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(query)) }
            }.value
            guard let self, !Task.isCancelled, self.unassignedGeneration == generation else { return }
            self.filteredUnassigned = result
            self.unassignedLoading = false
        }
    }

    private func refreshVisibleMessages() {
        filterGeneration += 1
        let generation = filterGeneration
        let source = messagesByConversation[currentConversation?.id ?? ""] ?? []
        let query = messageSearch
        let kind = mediaFilter
        let dateEnabled = useDateFilter
        let cutoff = Calendar.current.startOfDay(for: beforeDate).addingTimeInterval(86400)
        messageLimit = 200
        filteredMessageCache = []
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            let filtered = await Task.detached(priority: .userInitiated) { source.filter { message in
                (kind == "全部" || message.kind.rawValue == kind) &&
                (!dateEnabled || message.date < cutoff) &&
                (query.isEmpty || message.summary.localizedCaseInsensitiveContains(query) || message.localID.contains(query) ||
                 message.filePaths.contains { $0.localizedCaseInsensitiveContains(query) })
            } }.value
            await MainActor.run {
                guard let self, self.filterGeneration == generation else { return }
                self.filteredMessageCache = filtered
                self.analysisLoading = false
            }
        }
    }
    func selectAllVisibleMessages() {
        checkedMessages = Set(filteredMessageCache.lazy.filter { !$0.filePaths.isEmpty }.map(\.id))
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
