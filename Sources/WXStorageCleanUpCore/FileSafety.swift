import Foundation
import Darwin

public enum FileSafety {
    static func canonicalPath(_ url: URL) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { throw StorageError.invalid("无法解析文件的实际位置。") }
        return String(cString: buffer)
    }

    static func relativePath(_ url: URL, root: URL) throws -> String {
        let base = try canonicalPath(root), target = try canonicalPath(url)
        guard target.hasPrefix(base + "/") else { throw StorageError.invalid("项目不在扫描根目录内。") }
        return String(target.dropFirst(base.count + 1))
    }

    public static func identity(_ url: URL) throws -> FileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw StorageError.invalid("文件不可访问（系统错误 \(errno)）。")
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw StorageError.invalid("目标不是普通文件，已拒绝操作。")
        }
        return FileIdentity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino),
            bytes: Int64(metadata.st_size), modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanos: Int64(metadata.st_mtimespec.tv_nsec), links: UInt64(metadata.st_nlink))
    }

    public static func checkedURL(relativePath: String, root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else {
            throw StorageError.invalid("路径不在授权目录内。")
        }
        let base = root.standardizedFileURL
        // The explicitly selected root is the trust boundary. macOS itself aliases /var to /private/var;
        // rejecting system ancestors would also reject legitimate temporary-directory fixtures.
        var rootInfo = stat()
        guard lstat(base.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw StorageError.invalid("授权根目录不可访问或已被链接替换。")
        }
        var cursor = base
        for component in components.map(String.init) {
            cursor.appendPathComponent(component)
            var metadata = stat()
            guard lstat(cursor.path, &metadata) == 0 else {
                throw StorageError.invalid("文件或父目录已消失，需重新扫描。")
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                throw StorageError.invalid("路径包含符号链接，已拒绝操作。")
            }
        }
        return cursor
    }

    public static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func writePrivate<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
