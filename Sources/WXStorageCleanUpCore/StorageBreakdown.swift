import Foundation

/// WeChat data found outside the scanned folder, sized like the application bundle.
public struct RelatedLocation: Codable, Equatable, Sendable {
    public let path: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let complete: Bool
    public var name: String { (path as NSString).lastPathComponent }
}

/// One node of the "total → modules" tree. A node's size is the sum of its children's, and the root is all of
/// WeChat's scanned disk usage. Sizes are allocated space with every physical file counted once, in one module.
public struct StorageModule: Identifiable, Sendable {
    public enum Link: Equatable, Sendable { case chats(accountID: String), unassigned(accountID: String), legacy }
    public let id: String
    public let title: String
    public let detail: String
    public let allocatedBytes: Int64
    /// Paths in this module (a hardlinked file may also be listed in another module, but is sized only once).
    public let items: Int
    public let children: [StorageModule]
    public let link: Link?

    init(id: String, title: String, detail: String, allocatedBytes: Int64, items: Int, link: Link? = nil) {
        self.id = id; self.title = title; self.detail = detail
        self.allocatedBytes = allocatedBytes; self.items = items; self.children = []; self.link = link
    }
    init(id: String, title: String, detail: String, children: [StorageModule]) {
        self.id = id; self.title = title; self.detail = detail; self.children = children; self.link = nil
        allocatedBytes = children.reduce(0) { $0 + $1.allocatedBytes }
        items = children.reduce(0) { $0 + $1.items }
    }
    public func module(_ id: String) -> StorageModule? {
        if self.id == id { return self }
        for child in children { if let found = child.module(id) { return found } }
        return nil
    }
}

public struct StorageBreakdown: Sendable {
    public let total: StorageModule
    /// Physical files reachable through more than one path; each is sized once.
    public let sharedPhysicalFiles: Int
    public let complete: Bool
    public static func chatsID(_ accountID: String) -> String { "account:\(accountID)/chats" }
    public static func unassignedID(_ accountID: String) -> String { "account:\(accountID)/unassigned" }
    public static func accountID(_ accountID: String) -> String { "account:\(accountID)" }
}

/// The module a scanned file belongs to. Lower ranks win when one physical file has paths in several modules.
enum StorageLeaf: Hashable {
    case chatAttachments(String), otherAttachments(String), database(String), business(String), cache(String), accountOther(String)
    case legacy, backup, sharedAccountData, browser, plugins, logs, appCache, otherAppData

    var rank: Int {
        switch self {
        case .chatAttachments: 0
        case .otherAttachments: 1
        case .database: 2
        case .business: 3
        case .cache: 4
        case .accountOther: 5
        case .legacy: 6
        case .backup: 7
        case .sharedAccountData: 8
        case .browser: 9
        case .plugins: 10
        case .logs: 11
        case .appCache: 12
        case .otherAppData: 13
        }
    }

    static func classify(_ file: StoredFile, assigned: Set<String>, accounts: [String: Account], rootName: String) -> StorageLeaf {
        if file.category == .legacy { return .legacy }
        if let accountID = file.accountID {
            if file.category == .attachment {
                return assigned.contains(file.relativePath) ? .chatAttachments(accountID) : .otherAttachments(accountID)
            }
            let prefix = accounts[accountID]?.relativePath ?? ""
            let local = prefix.isEmpty ? file.relativePath : String(file.relativePath.dropFirst(prefix.count + 1))
            switch local.split(separator: "/").first {
            case "db_storage": return .database(accountID)
            case "business": return .business(accountID)
            case "cache", "temp": return .cache(accountID)
            default: return .accountOther(accountID)
            }
        }
        // Include the root's own name so "Backup/…" matches when xwechat_files itself was scanned.
        let parts = [rootName] + file.relativePath.split(separator: "/").map(String.init)
        func follows(_ first: String, _ second: String) -> Bool {
            zip(parts, parts.dropFirst()).contains { $0 == first && $1 == second }
        }
        if follows("app_data", "radium") { return .browser }
        if follows("app_data", "xplugin") { return .plugins }
        if follows("app_data", "log") || follows("app_data", "crashinfo") { return .logs }
        if follows("xwechat_files", "Backup") { return .backup }
        if follows("xwechat_files", "all_users") { return .sharedAccountData }
        if follows("Library", "Caches") { return .appCache }
        return .otherAppData
    }
}

extension Analysis {
    /// Splits all scanned WeChat usage into modules whose sizes add up exactly to the total.
    public func storageBreakdown() -> StorageBreakdown {
        let assigned = Set(conversations.flatMap(\.filePaths))
        let accounts = Dictionary(uniqueKeysWithValues: inventory.accounts.map { ($0.id, $0) })
        let rootName = inventory.root.lastPathComponent
        var owner = [String: (leaf: StorageLeaf, path: String, bytes: Int64)]()
        var paths = [String: Int](), items = [StorageLeaf: Int]()
        for file in inventory.files {
            let leaf = StorageLeaf.classify(file, assigned: assigned, accounts: accounts, rootName: rootName)
            items[leaf, default: 0] += 1
            let id = file.identity.physicalID
            paths[id, default: 0] += 1
            if let current = owner[id], (current.leaf.rank, current.path) <= (leaf.rank, file.relativePath) { continue }
            owner[id] = (leaf, file.relativePath, file.allocatedBytes)
        }
        var bytes = [StorageLeaf: Int64]()
        for value in owner.values { bytes[value.leaf, default: 0] += value.bytes }

        func leaf(_ key: StorageLeaf, _ id: String, _ title: String, _ detail: String, link: StorageModule.Link? = nil) -> StorageModule {
            StorageModule(id: id, title: title, detail: detail, allocatedBytes: bytes[key] ?? 0, items: items[key] ?? 0, link: link)
        }
        var modules = inventory.accounts.map { account in
            let id = account.id, base = StorageBreakdown.accountID(id)
            return StorageModule(id: base, title: "账号 · \(id)", detail: "xwechat_files 中的账号数据", children: [
                leaf(.chatAttachments(id), StorageBreakdown.chatsID(id), "聊天附件", "已对应到聊天的图片、视频、文件和语音", link: .chats(accountID: id)),
                leaf(.otherAttachments(id), StorageBreakdown.unassignedID(id), "其他附件", "尚未对应到聊天的附件", link: .unassigned(accountID: id)),
                leaf(.database(id), base + "/database", "聊天记录数据库", "db_storage：消息、联系人等加密数据库"),
                leaf(.business(id), base + "/business", "收藏、表情与朋友圈", "business：收藏、表情、朋友圈与内置网页"),
                leaf(.cache(id), base + "/cache", "账号缓存与临时文件", "cache、temp"),
                leaf(.accountOther(id), base + "/other", "其他账号文件", "资源、配置等"),
            ])
        }
        modules += [
            leaf(.browser, "browser", "内置浏览器与小程序", "app_data/radium：网页、小程序及其缓存"),
            leaf(.plugins, "plugins", "插件", "app_data/xplugin"),
            leaf(.logs, "logs", "日志与崩溃记录", "app_data/log、crashinfo"),
            leaf(.appCache, "app-cache", "系统缓存", "Library/Caches"),
            leaf(.backup, "backup", "聊天记录备份", "xwechat_files/Backup：备份与迁移数据"),
            leaf(.sharedAccountData, "shared-account", "账号公共数据", "xwechat_files/all_users：登录信息等"),
            leaf(.legacy, "legacy", "历史版本数据", "旧版微信（3.x）的数据库及未归属文件", link: .legacy),
            leaf(.otherAppData, "other", "其他应用数据", "设置、网络存储等其他文件"),
            StorageModule(id: "application", title: "应用程序", detail: "WeChat.app",
                allocatedBytes: inventory.applicationAllocatedBytes, items: inventory.applicationAllocatedBytes > 0 ? 1 : 0),
            StorageModule(id: "related", title: "扩展与共享容器", detail: "分享与文件扩展、Group Container、偏好设置",
                children: inventory.relatedLocations.map {
                    StorageModule(id: "related:" + $0.path, title: $0.name, detail: $0.path, allocatedBytes: $0.allocatedBytes, items: 1)
                }),
        ]
        let total = StorageModule(id: "total", title: "微信总占用", detail: inventory.root.path, children: modules)
        return StorageBreakdown(total: total, sharedPhysicalFiles: paths.values.filter { $0 > 1 }.count,
            complete: inventory.complete && inventory.applicationScanComplete && inventory.relatedLocations.allSatisfy(\.complete))
    }
}
