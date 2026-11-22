import Foundation

/// A folder or file in the old (3.x) client's data area that holds "历史版本数据" files. Legacy chat media already
/// merged into a current chat is left out: it is sized and cleaned with that chat.
public struct LegacyNode: Identifiable, Sendable {
    /// Path relative to the scan root.
    public let id: String
    public let name: String
    public let isDirectory: Bool
    /// What the old layout says this is, such as a legacy account folder and the current account it maps to.
    public let note: String?
    public let files: Int
    public let logicalBytes: Int64
    /// The space the overview's "历史版本数据" module counts for this node: every physical file once, files shared
    /// with current account data excluded. Children add up to their parent.
    public let allocatedBytes: Int64
    /// Files with more than one hardlink; trashing this path alone may not free their space.
    public let hardlinkedFiles: Int
    public let modifiedAt: Date
    /// The folder also holds files counted elsewhere (legacy media merged into chats); cleaning keeps those.
    public let mixed: Bool
    /// Inside a legacy account folder (`<version>/<32-hex>`), the only part verified to belong to the old client.
    public let cleanable: Bool
    public let children: [LegacyNode]
}

public struct LegacyData: Sendable {
    /// The `com.tencent.xinWeChat` folder; nil when the scan holds no legacy data.
    public let root: LegacyNode?
    private let nodes: [String: LegacyNode]
    public static let empty = LegacyData(root: nil)

    init(root: LegacyNode?) {
        self.root = root
        var nodes = [String: LegacyNode]()
        func index(_ node: LegacyNode) { nodes[node.id] = node; node.children.forEach(index) }
        if let root { index(root) }
        self.nodes = nodes
    }
    public func node(_ id: String) -> LegacyNode? { nodes[id] }
    /// The root and each folder down to `id`, for breadcrumbs.
    public func trail(to id: String) -> [LegacyNode] {
        guard let root else { return [] }
        var result = [root], path = root.id
        guard id.hasPrefix(root.id + "/") else { return result }
        for part in id.dropFirst(root.id.count + 1).split(separator: "/") {
            path += "/" + part
            guard let node = nodes[path] else { break }
            result.append(node)
        }
        return result
    }
}

extension Analysis {
    /// The legacy data area as a folder tree, sized like the overview's "历史版本数据" module.
    public func legacyData() -> LegacyData {
        let prefix = LegacyLayout.prefix
        let legacy = inventory.files.filter { $0.category == .legacy && $0.relativePath.hasPrefix(prefix) }
            .sorted { $0.relativePath < $1.relativePath }
        guard !legacy.isEmpty else { return .empty }
        // Same owner rule as the overview: a physical file with any path in account data is sized there,
        // otherwise at its first legacy path.
        let accountFiles = Set(inventory.files.lazy.filter { $0.category != .legacy && $0.accountID != nil }.map(\.identity.physicalID))
        var counted = Set<String>()
        let root = LegacyBuilder(name: "com.tencent.xinWeChat", path: String(prefix.dropLast()))
        for file in legacy {
            let id = file.identity.physicalID
            let owned = !accountFiles.contains(id) && counted.insert(id).inserted
            root.add(file, file.relativePath.dropFirst(prefix.count).split(separator: "/"), allocated: owned ? file.allocatedBytes : 0)
        }
        for file in inventory.files where file.category != .legacy && file.relativePath.hasPrefix(prefix) {
            root.markMixed(file.relativePath.dropFirst(prefix.count).split(separator: "/"))
        }
        return LegacyData(root: root.node(depth: 0, parent: nil, accounts: LegacyLayout.accountMap(inventory.accounts)))
    }
}

private final class LegacyBuilder {
    let name: String, path: String
    var children = [String: LegacyBuilder]()
    var isFile = false, mixed = false
    var files = 0, hardlinked = 0, logical: Int64 = 0, allocated: Int64 = 0, modified: Int64 = 0
    init(name: String, path: String) { self.name = name; self.path = path }

    func add(_ file: StoredFile, _ parts: [Substring], allocated bytes: Int64) {
        var node = self
        node.count(file, bytes)
        for part in parts {
            let key = String(part)
            let child: LegacyBuilder
            if let existing = node.children[key] { child = existing }
            else { child = LegacyBuilder(name: key, path: node.path + "/" + key); node.children[key] = child }
            child.count(file, bytes)
            node = child
        }
        node.isFile = true
    }
    private func count(_ file: StoredFile, _ bytes: Int64) {
        files += 1; logical += file.identity.bytes; allocated += bytes
        if file.identity.links > 1 { hardlinked += 1 }
        modified = max(modified, file.identity.modifiedSeconds)
    }
    /// Flags every listed folder that contains this file counted elsewhere.
    func markMixed(_ parts: [Substring]) {
        var node = self
        node.mixed = true
        for part in parts.dropLast() {
            guard let child = node.children[String(part)] else { return }
            child.mixed = true; node = child
        }
    }

    func node(depth: Int, parent: String?, accounts: [String: String]) -> LegacyNode {
        let children = self.children.values.map { $0.node(depth: depth + 1, parent: name, accounts: accounts) }.sorted {
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            if $0.logicalBytes != $1.logicalBytes { return $0.logicalBytes > $1.logicalBytes }
            return $0.name < $1.name
        }
        return LegacyNode(id: path, name: name, isDirectory: !isFile, note: note(depth: depth, parent: parent, accounts: accounts),
            files: files, logicalBytes: logical, allocatedBytes: allocated, hardlinkedFiles: hardlinked,
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(modified)), mixed: mixed,
            cleanable: LegacyLayout.locate(path) != nil && !(depth == 2 && isFile), children: children)
    }

    private static let folderNotes = ["Message": "聊天记录数据库与附件", "MessageTemp": "聊天图片、视频、语音与文件",
        "Favorites": "收藏", "Stickers": "表情", "Contact": "联系人", "Group": "群聊"]

    private func note(depth: Int, parent: String?, accounts: [String: String]) -> String? {
        if isFile {
            if name.hasPrefix("msg_") && name.hasSuffix(".db") { return "聊天记录数据库" }
            return name.hasSuffix(".db") || name.contains(".db-") ? "数据库文件" : nil
        }
        if depth == 2 && Scanner.isHash(name) {
            return accounts[name].map { "旧版账号 · 对应新版账号 \($0)" } ?? "旧版账号 · 未对应到新版账号"
        }
        if depth == 1 && children.values.contains(where: { !$0.isFile && Scanner.isHash($0.name) }) { return "旧版微信数据目录" }
        if parent == "MessageTemp" && Scanner.isHash(name) { return "单个聊天的图片、视频、语音和文件" }
        return Self.folderNotes[name]
    }
}
