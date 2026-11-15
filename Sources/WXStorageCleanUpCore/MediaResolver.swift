import Foundation
import CryptoKit
import Darwin

/// Resolves only explicit message metadata, then verifies the bytes. A filename is never proof of ownership.
enum MediaResolver {
    final class Context {
        var byName: [String: [StoredFile]] = [:]
        var digests: [String: (FileIdentity, String)] = [:]
        init(account: Account, inventory: Inventory) {
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
    }

    static func body(_ data: Data?) -> String? {
        guard let data, data.count <= 16 * 1024 * 1024 else { return nil }
        if data.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]) { return zstd(data).flatMap { String(data: $0, encoding: .utf8) } }
        return String(data: data, encoding: .utf8)
    }

    static func resolve(xml: String?, kind: MediaKind, account: Account, inventory: Inventory, context: Context? = nil) throws -> (paths: [String], summary: String, reason: String) {
        guard kind == .file || kind == .video else { return ([], "\(kind.rawValue)消息", "此消息类型未建立文件映射") }
        guard let xml, let start = xml.firstIndex(of: "<"), xml.utf8.count <= 16 * 1024 * 1024 else {
            return ([], "\(kind.rawValue)消息", "消息正文尚未解码，已保护")
        }
        let text = String(xml[start...])
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
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
            let digest: String
            if let cached = lookup.digests[file.identity.physicalID], cached.0 == file.identity {
                digest = cached.1
            } else {
                digest = try md5(url)
                lookup.digests[file.identity.physicalID] = (file.identity, digest)
            }
            guard try FileSafety.identity(url) == file.identity else { continue }
            if digest == expected { matched.append(file.relativePath) }
        }
        guard matched.count == 1 else {
            return ([], title, matched.isEmpty ? "未找到内容校验一致的原文件" : "多个文件内容相同，位置存在歧义，已保护")
        }
        return (matched, title, "消息元数据与文件内容 MD5 校验一致")
    }

    private static func md5(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func zstd(_ data: Data) -> Data? {
        let candidates: [String?] = [Bundle.main.privateFrameworksURL.map { $0.appendingPathComponent("libzstd.dylib").path },
                          SnapshotService.developmentDependencyRoot.appendingPathComponent("lib/libzstd.dylib").path,
                          "/opt/homebrew/opt/zstd/lib/libzstd.dylib", "/usr/local/opt/zstd/lib/libzstd.dylib", "/usr/lib/libzstd.dylib"]
        for path in candidates.compactMap({ $0 }) {
            guard let library = dlopen(path, RTLD_LOCAL | RTLD_LAZY) else { continue }
            defer { dlclose(library) }
            typealias SizeFunction = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
            typealias DecodeFunction = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
            guard let sizeSymbol = dlsym(library, "ZSTD_getFrameContentSize"), let decodeSymbol = dlsym(library, "ZSTD_decompress") else { continue }
            let sizeFunction = unsafeBitCast(sizeSymbol, to: SizeFunction.self)
            let decode = unsafeBitCast(decodeSymbol, to: DecodeFunction.self)
            let size = data.withUnsafeBytes { sizeFunction($0.baseAddress, data.count) }
            guard size <= 16 * 1024 * 1024 else { return nil }
            var output = Data(count: Int(size))
            let result = output.withUnsafeMutableBytes { destination in data.withUnsafeBytes { source in
                decode(destination.baseAddress, Int(size), source.baseAddress, data.count)
            } }
            guard result == Int(size) else { return nil }
            return output
        }
        return nil
    }
}

private final class MessageXML: NSObject, XMLParserDelegate {
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
        if elementName == "appattach" { hasAttachment = true }
        if elementName == "videomsg" { videoMD5 = attributes["md5"] ?? ""; videoLength = attributes["length"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { values[path.joined(separator: "/"), default: ""] += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { values[path.joined(separator: "/"), default: ""] += value }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !path.isEmpty { path.removeLast() } }
}
