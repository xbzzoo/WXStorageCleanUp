import Foundation
import CSQLite

enum SQLValue {
    case text(String), integer(Int64), blob(Data), null
    var string: String {
        switch self { case .text(let v): return v; case .integer(let v): return String(v); default: return "" }
    }
    var int: Int64 { if case .integer(let v) = self { return v }; return Int64(string) ?? 0 }
    var data: Data? {
        switch self { case .blob(let v): return v; case .text(let v): return Data(v.utf8); default: return nil }
    }
}

final class ReadOnlyDatabase {
    private var handle: OpaquePointer?
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw StorageError.invalid("无法读取索引：需要有效的已解密 SQLite 数据库。")
        }
        try execute("PRAGMA query_only=ON")
        _ = try query("SELECT name FROM sqlite_master LIMIT 1")
    }
    deinit { if let handle { sqlite3_close(handle) } }
    private func execute(_ sql: String) throws { _ = try query(sql) }
    func query(_ sql: String) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库未打开"
            throw StorageError.invalid("索引只读查询失败：\(reason)")
        }
        defer { sqlite3_finalize(statement) }
        var rows = [[String: SQLValue]]()
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw StorageError.invalid("索引读取失败，数据可能不完整。") }
            var row = [String: SQLValue]()
            for column in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_TEXT:
                    if let pointer = sqlite3_column_text(statement, column) { row[key] = .text(String(cString: pointer)) }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row[key] = .blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data())
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }
    func columns(_ table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_info(\(Self.identifier(table)))").map { $0["name"]?.string ?? "" })
    }
    func require(_ table: String, _ fields: Set<String>) throws {
        guard fields.isSubset(of: try columns(table)) else {
            throw StorageError.invalid("不支持的索引结构：\(table)。已停止解析，未修改微信数据。")
        }
    }
    static func identifier(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
}

func copyPlainDatabase(source: URL, destination: URL) throws {
    var input: OpaquePointer?, output: OpaquePointer?
    defer { if let input { sqlite3_close(input) }; if let output { sqlite3_close(output) } }
    guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let backup = sqlite3_backup_init(output, "main", input, "main") else {
        throw StorageError.invalid("无法建立一致的索引副本。")
    }
    let result = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finished == SQLITE_OK else { throw StorageError.invalid("索引副本创建失败。") }
    // Backup inherits the source's WAL-mode page header. Normalize our private output to
    // a self-contained database before hashing/importing; it must not require sidecars.
    guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
        throw StorageError.invalid("无法将索引快照转换为独立数据库。")
    }
}

extension Dictionary where Key == String, Value == SQLValue {
    func text(_ key: String) -> String { self[key]?.string ?? "" }
    func number(_ key: String) -> Int64 { self[key]?.int ?? 0 }
}
