import Foundation
import CryptoKit
import Darwin

/// MD5 of a file's content, valid only while the file keeps the same identity (device, inode, size, mtime, links).
struct DigestEntry: Codable, Equatable, Sendable {
    let identity: FileIdentity
    let md5: String
}

/// Persists content digests between launches, so unchanged files are not re-read on every index load.
/// Holds no paths or names; entries are keyed by physical file and checked against the file's identity.
enum DigestCache {
    private struct Contents: Codable { let version: Int; let entries: [String: DigestEntry] }
    static func read(_ url: URL?) -> [String: DigestEntry] {
        guard let url, let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data), contents.version == 1 else { return [:] }
        return contents.entries
    }
    /// Best effort: the cache only saves time, so a failed write is not an error.
    static func write(_ entries: [String: DigestEntry], to url: URL) {
        guard let data = try? JSONEncoder().encode(Contents(version: 1, entries: entries)) else { return }
        try? FileSafety.privateDirectory(url.deletingLastPathComponent())
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Resolves only explicit message metadata, then verifies the bytes. A filename is never proof of ownership.
enum MediaResolver {
    final class Context {
        var byName: [String: [StoredFile]] = [:]
        /// Digests used during this load; saved back as the next launch's cache, which also drops stale entries.
        private(set) var digests: [String: DigestEntry] = [:]
        private let persisted: [String: DigestEntry]
        init(account: Account, inventory: Inventory, persisted: [String: DigestEntry] = [:]) {
            self.persisted = persisted
            for file in inventory.files where file.accountID == account.id && file.category == .attachment {
                let local = account.relativePath.isEmpty ? file.relativePath : String(file.relativePath.dropFirst(account.relativePath.count + 1))
                if local.hasPrefix("msg/video/") {
                    byName["video:" + (file.name as NSString).deletingPathExtension.lowercased(), default: []].append(file)
                } else if local.hasPrefix("msg/file/") {
                    byName["file:" + file.name, default: []].append(file)
                    let stem = (file.name as NSString).deletingPathExtension
                    let normalized = stem.replacingOccurrences(of: " ?\\([0-9]+\\)$", with: "", options: .regularExpression)
                    if normalized != stem {
                        let ext = (file.name as NSString).pathExtension
                        byName["file:" + normalized + (ext.isEmpty ? "" : "." + ext), default: []].append(file)
                    }
                }
            }
        }
        /// The file's MD5, from this load or the persisted cache when its identity is unchanged, else read from disk.
        func digest(of file: StoredFile, at url: URL) throws -> String {
            let id = file.identity.physicalID
            if let entry = digests[id] ?? persisted[id], entry.identity == file.identity {
                digests[id] = entry
                return entry.md5
            }
            let value = try MediaResolver.md5(url)
            digests[id] = DigestEntry(identity: file.identity, md5: value)
            return value
        }
    }

    /// True when the XML declares a DTD or entity. XML keywords are ASCII, so a byte scan replaces a
    /// locale-aware search that cost about a tenth of index loading.
    static func declaresDTD(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            let keywords = [Array("doctype".utf8), Array("entity".utf8)]
            var index = 0
            while index + 1 < bytes.count {
                if bytes[index] == UInt8(ascii: "<"), bytes[index + 1] == UInt8(ascii: "!") {
                    for keyword in keywords where index + 2 + keyword.count <= bytes.count {
                        if keyword.indices.allSatisfy({ bytes[index + 2 + $0] | 0x20 == keyword[$0] }) { return true }
                    }
                }
                index += 1
            }
            return false
        }
    }

    static func body(_ data: Data?) -> String? {
        guard let data, data.count <= 16 * 1024 * 1024 else { return nil }
        if data.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]) { return zstd(data).flatMap { String(data: $0, encoding: .utf8) } }
        return String(data: data, encoding: .utf8)
    }

    static func imageIdentifier(_ xml: String?) -> String? {
        guard let xml, xml.utf8.count <= 16 * 1024 * 1024, let start = xml.firstIndex(of: "<") else { return nil }
        let text = String(xml[start...])
        guard !declaresDTD(text) else { return nil }
        let metadata = MessageXML()
        let parser = XMLParser(data: Data(text.utf8)); parser.delegate = metadata; parser.shouldResolveExternalEntities = false
        guard parser.parse(), metadata.imageIDs.count == 1, let identifier = metadata.imageIDs.first,
              Scanner.isHash(identifier) else { return nil }
        return identifier
    }

    static func resolve(xml: String?, kind: MediaKind, account: Account, inventory: Inventory, context: Context? = nil) throws -> (paths: [String], summary: String, reason: String) {
        guard kind == .file || kind == .video else { return ([], "\(kind.rawValue)消息", "此消息类型未建立文件映射") }
        guard let xml, let start = xml.firstIndex(of: "<"), xml.utf8.count <= 16 * 1024 * 1024 else {
            return ([], "\(kind.rawValue)消息", "消息正文尚未解码，已保护")
        }
        let text = String(xml[start...])
        guard !declaresDTD(text) else {
            return ([], "\(kind.rawValue)消息", "消息含不支持的 XML 定义，已保护")
        }
        let metadata = MessageXML()
        let parser = XMLParser(data: Data(text.utf8)); parser.delegate = metadata; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return ([], "\(kind.rawValue)消息", "消息结构未识别，已保护") }
        let expected: String, title: String, size: Int64?
        if kind == .file {
            guard metadata.appType == "6", metadata.hasAttachment else {
                return ([], "链接或其他卡片消息", "不是可清理的文件消息")
            }
            expected = metadata.fileMD5.lowercased(); title = metadata.title
            size = Int64(metadata.fileLength)
            guard !title.isEmpty, !title.contains("/"), !title.contains("\\"), title != ".", title != ".." else {
                return ([], "文件消息", "文件名不安全，已保护")
            }
        } else {
            expected = metadata.videoMD5.lowercased(); title = "视频消息"; size = Int64(metadata.videoLength)
        }
        guard Scanner.isHash(expected) else { return ([], title, "消息缺少可靠的内容校验值，已保护") }
        let lookup = context ?? Context(account: account, inventory: inventory)
        let candidates = (lookup.byName[(kind == .video ? "video:" + expected : "file:" + title)] ?? []).filter {
            size == nil || size == 0 || $0.identity.bytes == size
        }
        var matched = [String]()
        for file in candidates {
            try Task.checkCancellation()
            let url = try FileSafety.checkedURL(relativePath: file.relativePath, root: inventory.root)
            guard try FileSafety.identity(url) == file.identity else { continue }
            let digest = try lookup.digest(of: file, at: url)
            guard try FileSafety.identity(url) == file.identity else { continue }
            if digest == expected { matched.append(file.relativePath) }
        }
        guard matched.count == 1 else {
            return ([], title, matched.isEmpty ? "未找到内容校验一致的原文件" : "多个文件内容相同，位置存在歧义，已保护")
        }
        return (matched, title, "消息元数据与文件内容 MD5 校验一致")
    }

    static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Resolved once per process: loading and unloading the library for every message body dominated index loading.
    private struct ZstdLibrary: @unchecked Sendable {
        typealias SizeFunction = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
        typealias DecodeFunction = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
        let frameContentSize: SizeFunction
        let decompress: DecodeFunction

        static let shared: ZstdLibrary? = {
            let candidates: [String?] = [Bundle.main.privateFrameworksURL.map { $0.appendingPathComponent("libzstd.dylib").path },
                              SnapshotService.developmentDependencyRoot.appendingPathComponent("lib/libzstd.dylib").path,
                              "/opt/homebrew/opt/zstd/lib/libzstd.dylib", "/usr/local/opt/zstd/lib/libzstd.dylib", "/usr/lib/libzstd.dylib"]
            for path in candidates.compactMap({ $0 }) {
                guard let library = dlopen(path, RTLD_LOCAL | RTLD_LAZY) else { continue }
                guard let sizeSymbol = dlsym(library, "ZSTD_getFrameContentSize"), let decodeSymbol = dlsym(library, "ZSTD_decompress") else {
                    dlclose(library); continue
                }
                // Intentionally never closed: the handle stays valid for the life of the process.
                return ZstdLibrary(frameContentSize: unsafeBitCast(sizeSymbol, to: SizeFunction.self),
                                   decompress: unsafeBitCast(decodeSymbol, to: DecodeFunction.self))
            }
            return nil
        }()
    }

    private static func zstd(_ data: Data) -> Data? {
        guard let library = ZstdLibrary.shared else { return nil }
        let size = data.withUnsafeBytes { library.frameContentSize($0.baseAddress, data.count) }
        guard size <= 16 * 1024 * 1024 else { return nil }
        var output = Data(count: Int(size))
        let result = output.withUnsafeMutableBytes { destination in data.withUnsafeBytes { source in
            library.decompress(destination.baseAddress, Int(size), source.baseAddress, data.count)
        } }
        guard result == Int(size) else { return nil }
        return output
    }
}

private final class MessageXML: NSObject, XMLParserDelegate {
    var imageIDs: [String] = []
    var path = [String](), values = [String: String](), videoMD5 = "", videoLength = "", hasAttachment = false
    var appType: String { value("appmsg/type") }
    var title: String { value("appmsg/title") }
    var fileMD5: String { value("appmsg/md5") }
    var fileLength: String { value("appmsg/appattach/totallen") }
    func value(_ suffix: String) -> String {
        let found = values.filter { $0.key == suffix || $0.key.hasSuffix("/" + suffix) }
        return found.count == 1 ? found.first!.value.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        path.append(elementName)
        if elementName == "img", path == ["msg", "img"], let identifier = attributes["md5"] { imageIDs.append(identifier.lowercased()) }
        if elementName == "appattach" { hasAttachment = true }
        if elementName == "videomsg" { videoMD5 = attributes["md5"] ?? ""; videoLength = attributes["length"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { values[path.joined(separator: "/"), default: ""] += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { values[path.joined(separator: "/"), default: ""] += value }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !path.isEmpty { path.removeLast() } }
}
