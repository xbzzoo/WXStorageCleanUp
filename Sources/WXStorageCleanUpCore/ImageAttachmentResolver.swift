import Foundation

/// Index scanned image paths once. Hardlink metadata can be stale or omit local
/// variants; the actual file must still belong to this account and chat folder.
struct ImageAttachmentResolver {
    private var paths: [String: [String: [String]]] = [:]

    init(account: Account, inventory: Inventory) {
        for file in inventory.files where file.accountID == account.id && file.category == .attachment {
            let local = account.relativePath.isEmpty ? file.relativePath : String(file.relativePath.dropFirst(account.relativePath.count + 1))
            let parts = local.split(separator: "/").map(String.init)
            guard parts.count == 6, parts[0] == "msg", parts[1] == "attach",
                  Scanner.isHash(parts[2]), IndexReader.validMonth(parts[3]), parts[4] == "Img" else { continue }
            let name = parts[5] as NSString
            guard ["dat", "jpg", "jpeg", "png", "gif", "heic", "webp"].contains(name.pathExtension.lowercased()) else { continue }
            let stem = name.deletingPathExtension.lowercased()
            guard stem.count >= 32 else { continue }
            let identifier = String(stem.prefix(32)), suffix = String(stem.dropFirst(32))
            guard Scanner.isHash(identifier), suffix.isEmpty || suffix.hasPrefix("_") else { continue }
            paths[parts[2].lowercased() + ":" + identifier, default: [:]][parts[3], default: []].append(file.relativePath)
        }
    }

    func resolve(identifier: String, chat: String) -> (paths: [String], reason: String) {
        let locations = paths[chatHash(chat) + ":" + identifier.lowercased()] ?? [:]
        guard locations.count <= 1 else { return ([], "图片标识对应多个月份目录，暂未关联") }
        let candidates = locations.values.first ?? []
        let sorted = candidates.sorted {
            let left = Self.rank($0), right = Self.rank($1)
            return left == right ? $0 < $1 : left < right
        }
        return (sorted, sorted.isEmpty ? "未匹配到本地图片：可能未下载、已清理或存储格式尚未适配" : "图片资源标识与当前聊天本地文件匹配")
    }

    private static func rank(_ path: String) -> Int {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if stem.hasSuffix("_t") || stem.hasSuffix("_thumb") { return 2 }
        if stem.count == 32 { return 0 }
        return 1
    }
}
