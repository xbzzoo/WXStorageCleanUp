import Foundation
import CryptoKit

public struct SavedAccountConnection: Codable, Sendable {
    public let accountID: String
    public let rootPath: String
    public let snapshotPath: String
    public let connectedAt: Date
}

/// Scope persisted state by the real storage root AND account, never just a displayed name.
public struct AccountConnectionStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatStorage/Connections")) {
        self.directory = directory
    }
    public static func namespace(root: URL, accountID: String) -> String {
        let path = (try? FileSafety.canonicalPath(root)) ?? root.standardizedFileURL.path
        let input = Data((path + "\0" + accountID).utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
    public func accountDirectory(root: URL, accountID: String) -> URL {
        directory.appendingPathComponent(Self.namespace(root: root, accountID: accountID))
    }
    public func keyFile(root: URL, accountID: String) -> URL {
        accountDirectory(root: root, accountID: accountID).appendingPathComponent("keys.json")
    }
    public func save(accountID: String, root: URL, snapshot: URL) throws {
        let folder = accountDirectory(root: root, accountID: accountID)
        try FileSafety.privateDirectory(folder)
        try FileSafety.writePrivate(SavedAccountConnection(accountID: accountID, rootPath: root.path,
            snapshotPath: snapshot.path, connectedAt: Date()), to: folder.appendingPathComponent("connection.json"))
    }
    public func saved(accountID: String, root: URL) -> SavedAccountConnection? {
        let path = accountDirectory(root: root, accountID: accountID).appendingPathComponent("connection.json")
        guard let data = try? Data(contentsOf: path),
              let connection = try? JSONDecoder().decode(SavedAccountConnection.self, from: data),
              connection.accountID == accountID,
              URL(fileURLWithPath: connection.rootPath).standardizedFileURL == root.standardizedFileURL else { return nil }
        return connection
    }
    public func forget(accountID: String, root: URL) throws {
        let folder = accountDirectory(root: root, accountID: accountID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    public static func selectionKey(root: URL) -> String { "selectedAccount." + namespace(root: root, accountID: "") }
}

public struct AccountSelection: Sendable {
    public private(set) var accountID: String?
    public private(set) var conversationIDs = Set<String>()
    public private(set) var messageIDs = Set<String>()
    public init() {}
    public mutating func select(_ id: String, available: [Account]) throws {
        guard available.contains(where: { $0.id == id }) else { throw StorageError.invalid("所选账号不在当前扫描范围。") }
        if id != accountID { accountID = id; conversationIDs = []; messageIDs = [] }
    }
    public mutating func setSelection(conversations: Set<String>, messages: Set<String>) {
        conversationIDs = conversations; messageIDs = messages
    }
}
