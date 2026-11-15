import XCTest
import CommonCrypto
@testable import WXStorageCleanUpCore

final class ImageDecoderTests: XCTestCase {
    let image = Data([0xff, 0xd8, 0xff] + (0..<80).map { UInt8($0) } + [0xff, 0xd9])
    func testPlainAndLegacyXOR() throws {
        XCTAssertEqual(try LocalImageDecoder.decode(image), image)
        let encrypted = Data(image.map { $0 ^ 0x91 })
        XCTAssertEqual(try LocalImageDecoder.decode(encrypted), image)
    }
    func envelope(version: UInt8, key: [UInt8]) throws -> Data {
        let first = Data(image.prefix(32)), rest = Data(image.dropFirst(32))
        var out = [UInt8](repeating: 0, count: first.count + 16), written = 0
        let capacity = out.count
        let status = key.withUnsafeBytes { k in first.withUnsafeBytes { input in out.withUnsafeMutableBytes { output in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                k.baseAddress, 16, nil, input.baseAddress, first.count, output.baseAddress, capacity, &written)
        } } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        var data = Data([7, 8, 86, version, 8, 7])
        for value: UInt32 in [32, UInt32(rest.count)] {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(0); data.append(contentsOf: out.prefix(written))
        data.append(contentsOf: rest.map { $0 ^ 0x47 })
        return data
    }
    func testV1AndV2AndMissingKey() throws {
        let v1 = try envelope(version: 49, key: Array("cfcd208495d565ef".utf8))
        XCTAssertEqual(try LocalImageDecoder.decode(v1), image)
        let key = "abcdefghijklmnop"
        let v2 = try envelope(version: 50, key: Array(key.utf8))
        XCTAssertThrowsError(try LocalImageDecoder.decode(v2))
        XCTAssertEqual(try LocalImageDecoder.decode(v2, imageKey: key), image)
        XCTAssertEqual(try LocalImageDecoder.decode(v2, imageKey: Array(key.utf8).map { String(format: "%02x", $0) }.joined()), image)
        XCTAssertThrowsError(try LocalImageDecoder.decode(v2, imageKey: "wrongwrongwrong!!"))
    }
    func testMalformedEnvelope() {
        XCTAssertThrowsError(try LocalImageDecoder.decode(Data([7, 8, 86, 49, 8, 7])))
        XCTAssertThrowsError(try LocalImageDecoder.decode(Data([7, 8, 86, 49, 8, 7] + Array(repeating: 255, count: 9))))
    }
}
