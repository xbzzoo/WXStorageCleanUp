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
    /// Plaintext index snapshots. Only the snapshot a saved connection uses is kept.
    public let snapshotDirectory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WeChatStorage/Connections"), snapshotDirectory: URL? = nil) {
        self.directory = directory
        // Defaults to the sibling "Snapshots" folder, so a store in a temporary folder never touches real snapshots.
        self.snapshotDirectory = snapshotDirectory ?? directory.deletingLastPathComponent().appendingPathComponent("Snapshots")
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
    /// File content digests reused across index loads; removed with the rest of the account's folder on forget.
    public func digestCacheFile(root: URL, accountID: String) -> URL {
        accountDirectory(root: root, accountID: accountID).appendingPathComponent("digests.json")
    }
    public func save(accountID: String, root: URL, snapshot: URL) throws {
        let previous = saved(accountID: accountID, root: root)
        let folder = accountDirectory(root: root, accountID: accountID)
        try FileSafety.privateDirectory(folder)
        try FileSafety.writePrivate(SavedAccountConnection(accountID: accountID, rootPath: root.path,
            snapshotPath: snapshot.path, connectedAt: Date()), to: folder.appendingPathComponent("connection.json"))
        // The snapshot this connection replaces is no longer used.
        if let previous, previous.snapshotPath != snapshot.path { removeSnapshot(URL(fileURLWithPath: previous.snapshotPath)) }
    }

    /// Removes one `<snapshotDirectory>/<UUID>/db_storage` snapshot folder; any other path is left untouched.
    public func removeSnapshot(_ snapshot: URL) {
        let snapshot = snapshot.standardizedFileURL, folder = snapshot.deletingLastPathComponent()
        guard snapshot.lastPathComponent == "db_storage", UUID(uuidString: folder.lastPathComponent) != nil,
              folder.deletingLastPathComponent().resolvingSymlinksInPath().path ==
                snapshotDirectory.standardizedFileURL.resolvingSymlinksInPath().path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes every snapshot folder no saved connection uses: leftovers from failed or replaced connections.
    /// Folders changed within `grace` are skipped, so a snapshot still being created is never removed.
    @discardableResult
    public func pruneUnusedSnapshots(now: Date = Date(), grace: TimeInterval = 600) -> Int {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(at: snapshotDirectory, includingPropertiesForKeys: keys) else { return 0 }
        var folders = [URL]()
        if fileManager.fileExists(atPath: directory.path) {
            // If saved connections cannot be listed, nothing is known to be unused.
            guard let listed = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
            folders = listed
        }
        let used = Set(folders.compactMap { folder -> String? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("connection.json")),
                  let saved = try? JSONDecoder().decode(SavedAccountConnection.self, from: data) else { return nil }
            return URL(fileURLWithPath: saved.snapshotPath).deletingLastPathComponent().lastPathComponent
        })
        var removed = 0
        for entry in entries where UUID(uuidString: entry.lastPathComponent) != nil && !used.contains(entry.lastPathComponent) {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isSymbolicLink != true,
                  now.timeIntervalSince(values.contentModificationDate ?? now) > grace else { continue }
            if (try? fileManager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
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
        let previous = saved(accountID: accountID, root: root)
        let folder = accountDirectory(root: root, accountID: accountID)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        if let previous { removeSnapshot(URL(fileURLWithPath: previous.snapshotPath)) }
    }
    public static func selectionKey(root: URL) -> String { "selectedAccount." + namespace(root: root, accountID: "") }
}
