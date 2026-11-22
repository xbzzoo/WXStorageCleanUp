import Foundation

/// Layout of the old (3.x) macOS WeChat client inside the container's Data folder:
///
///     Library/Application Support/com.tencent.xinWeChat/<version>/<MD5(username)>/
///         Message/MessageTemp/<MD5(chat username)>/{Image,Video,Audio,File,OpenData,…}
///
/// The current client names the account folder `<username>_<4 hex>`, so the legacy account folder is the
/// MD5 of that name without the suffix. Chat folders use the same `chatHash` as `msg/attach/<hash>`,
/// which lets legacy media join the same conversation without decrypting the old databases.
public enum LegacyLayout {
    public static let prefix = "Library/Application Support/com.tencent.xinWeChat/"

    struct Location: Equatable {
        let accountHash: String
        let chatHash: String?
        let chatFolder: String?
    }

    /// Legacy account folder name → scanned account ID. A hash claimed by more than one account is dropped.
    static func accountMap(_ accounts: [Account]) -> [String: String] {
        var owners = [String: Set<String>]()
        for account in accounts {
            guard let username = username(fromAccountFolder: account.id) else { continue }
            owners[chatHash(username), default: []].insert(account.id)
        }
        return owners.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// `wxid_abc_1f2e` → `wxid_abc`. Folders without the 4-hex suffix have no verified legacy mapping.
    static func username(fromAccountFolder name: String) -> String? {
        guard let suffix = name.range(of: "_[0-9a-fA-F]{4}$", options: .regularExpression),
              suffix.lowerBound > name.startIndex else { return nil }
        return String(name[..<suffix.lowerBound])
    }

    /// Parses a path relative to the scanned Data folder; nil outside a legacy account folder.
    static func locate(_ relative: String) -> Location? {
        guard relative.hasPrefix(prefix) else { return nil }
        let parts = relative.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, Scanner.isHash(parts[1]) else { return nil }
        if parts.count >= 6, parts[2] == "Message", parts[3] == "MessageTemp", Scanner.isHash(parts[4]),
           !parts[5...].contains(where: \.isEmpty) {
            return Location(accountHash: parts[1], chatHash: parts[4], chatFolder: prefix + parts[0...4].joined(separator: "/"))
        }
        return Location(accountHash: parts[1], chatHash: nil, chatFolder: nil)
    }

    /// The legacy `MessageTemp/<chat hash>` folder that contains this path, if any.
    public static func chatFolder(containing relative: String) -> String? { locate(relative)?.chatFolder }
}
