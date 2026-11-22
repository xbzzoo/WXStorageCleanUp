import XCTest
import Foundation
@testable import WXStorageCleanUpCore

/// Index-loading shortcuts must not change results: cached digests, the DTD byte scan, the precomputed kind.
final class IndexLoadingTests: XCTestCase {
    var temporaryDirectories = [URL]()
    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WeChatIndexLoadingTests-" + UUID().uuidString)
        try FileSafety.privateDirectory(url); temporaryDirectories.append(url); return url
    }

    func testDigestsPersistAndAreReusedOnlyWhileTheFileIsUnchanged() throws {
        let demo = try DemoFactory.create(parent: temporary())
        var inventory = try Scanner.scan(root: demo.root)
        let cache = try temporary().appendingPathComponent("digests.json")
        func videoPaths() throws -> [String] {
            let index = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory, digestCache: cache)
            return try XCTUnwrap(index.messages.first { $0.kind == .video }).filePaths
        }
        func contents() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any]) }

        XCTAssertEqual(try videoPaths().count, 1)
        let entries = try XCTUnwrap(try contents()["entries"] as? [String: [String: Any]])
        XCTAssertEqual(entries.count, 2, "the video and the document both messages share")
        XCTAssertFalse(String(decoding: try Data(contentsOf: cache), as: UTF8.self).contains("msg/"), "no paths in the cache")

        // While a file's identity is unchanged its cached digest is used as is: corrupt it and the match disappears.
        var corrupted = entries.mapValues { entry -> [String: Any] in
            var entry = entry; entry["md5"] = String(repeating: "0", count: 32); return entry
        }
        corrupted["1:1"] = entries.values.first
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": corrupted]).write(to: cache)
        XCTAssertTrue(try videoPaths().isEmpty)
        XCTAssertNil((try contents()["entries"] as? [String: Any])?["1:1"], "only digests used by the load are kept")

        // Touching the file changes its identity: the stale entry is ignored and the content verified again.
        let video = try XCTUnwrap(inventory.files.first { $0.relativePath.contains("/msg/video/") })
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: demo.root.appendingPathComponent(video.relativePath).path)
        inventory = try Scanner.scan(root: demo.root)
        XCTAssertEqual(try videoPaths().count, 1)
    }

    func testIndexLoadsWithoutACacheFile() throws {
        let demo = try DemoFactory.create(parent: temporary())
        let inventory = try Scanner.scan(root: demo.root)
        let missing = try temporary().appendingPathComponent("absent/digests.json")
        let cached = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory, digestCache: missing)
        let plain = try IndexReader.load(snapshot: demo.snapshot, account: inventory.accounts[0], inventory: inventory)
        XCTAssertEqual(cached.messages.map(\.filePaths), plain.messages.map(\.filePaths))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDTDDetectionIsCaseInsensitiveAndIgnoresOrdinaryMarkup() {
        XCTAssertTrue(MediaResolver.declaresDTD("<!DOCTYPE msg>"))
        XCTAssertTrue(MediaResolver.declaresDTD("<msg><!doctype x></msg>"))
        XCTAssertTrue(MediaResolver.declaresDTD("<!Entity x 'y'>"))
        XCTAssertFalse(MediaResolver.declaresDTD("<msg><!-- 备注 --><title><![CDATA[项目说明.txt]]></title></msg>"))
        XCTAssertFalse(MediaResolver.declaresDTD("<!DOC"))
        XCTAssertFalse(MediaResolver.declaresDTD(""))
    }

    func testAttachmentKindIsDerivedOnceFromThePath() throws {
        XCTAssertEqual(StoredFile.kind(of: "acct/msg/attach/x/2026-10/Img/a.dat"), .image)
        XCTAssertEqual(StoredFile.kind(of: "msg/file/2026-10/PHOTO.JPG"), .image)
        XCTAssertEqual(StoredFile.kind(of: "acct/msg/video/2026-10/abc"), .video)
        XCTAssertEqual(StoredFile.kind(of: "msg/file/2026-10/archive.tar.gz"), .file)
        XCTAssertEqual(StoredFile.kind(of: "msg/file/2026-10/voice.AMR"), .voice)
        XCTAssertEqual(StoredFile.kind(of: LegacyLayout.prefix + "2.0b4.0.9/h/Message/MessageTemp/c/Audio/1"), .voice)
        let file = StoredFile(relativePath: "msg/file/a.mp4",
            identity: FileIdentity(device: 1, inode: 2, bytes: 3, modifiedSeconds: 4, modifiedNanos: 5, links: 1),
            allocatedBytes: 4096, category: .attachment, accountID: "a", directoryChatHash: nil)
        let data = try JSONEncoder().encode(file)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("attachmentKind"), "encoded form unchanged")
        XCTAssertEqual(try JSONDecoder().decode(StoredFile.self, from: data).attachmentKind, .video)
    }
}
