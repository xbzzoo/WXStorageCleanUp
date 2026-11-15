import Foundation
import CommonCrypto

/// Image keys are separate from database keys. Decoded bytes stay in memory.
public enum LocalImageDecoder {
    public static func decode(_ data: Data, imageKey: String = "") throws -> Data {
        guard data.count <= 32 * 1024 * 1024 else { throw StorageError.invalid("图片超过 32MB 预览限制，可在 Finder 中查看。") }
        let bytes = [UInt8](data)
        let v1: [UInt8] = [7, 8, 86, 49, 8, 7], v2: [UInt8] = [7, 8, 86, 50, 8, 7]
        if Array(bytes.prefix(6)) == v1 || Array(bytes.prefix(6)) == v2 {
            guard bytes.count >= 15 else { throw StorageError.invalid("图片文件不完整。") }
            let key: [UInt8]
            if Array(bytes.prefix(6)) == v1 { key = Array("cfcd208495d565ef".utf8) }
            else {
                let text = imageKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count == 32, text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
                    key = stride(from: 0, to: 32, by: 2).map { i in
                        let start = text.index(text.startIndex, offsetBy: i)
                        return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
                    }
                } else if text.utf8.count == 16 { key = Array(text.utf8) }
                else { throw StorageError.invalid("这是 V2 加密图片，需要独立的图片 AES 密钥；数据库密钥不能直接替代。可在图片面板的高级选项中填写已有图片密钥。") }
            }
            func number(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) } }
            let aesSize = number(6), xorSize = number(10), encryptedSize = (aesSize / 16 + 1) * 16
            guard encryptedSize <= bytes.count - 15, xorSize <= bytes.count - 15 - encryptedSize else {
                throw StorageError.invalid("加密图片长度无效。")
            }
            let encrypted = Array(bytes[15..<15 + encryptedSize])
            var output = [UInt8](repeating: 0, count: encryptedSize + 16), written = 0
            let capacity = output.count
            let result = key.withUnsafeBytes { k in encrypted.withUnsafeBytes { input in output.withUnsafeMutableBytes { destination in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    k.baseAddress, 16, nil, input.baseAddress, encrypted.count, destination.baseAddress, capacity, &written)
            } } }
            guard result == kCCSuccess, written == aesSize else { throw StorageError.invalid("图片密钥不匹配或文件损坏。") }
            let rawEnd = bytes.count - xorSize
            var plain = Array(output.prefix(written)) + Array(bytes[(15 + encryptedSize)..<rawEnd])
            var xorKey: UInt8 = 0x88
            if xorSize >= 2, plain.starts(with: [0xff, 0xd8]), bytes[bytes.count - 2] ^ 0xff == bytes[bytes.count - 1] ^ 0xd9 {
                xorKey = bytes[bytes.count - 1] ^ 0xd9
            } else if xorSize >= 4, plain.starts(with: [0x89, 0x50, 0x4e, 0x47]) {
                let tail: [UInt8] = [0xae, 0x42, 0x60, 0x82]
                let candidate = bytes[bytes.count - 1] ^ tail[3]
                if (0..<4).allSatisfy({ bytes[bytes.count - 4 + $0] ^ candidate == tail[$0] }) { xorKey = candidate }
            }
            plain += bytes[rawEnd...].map { $0 ^ xorKey }
            return Data(plain)
        }
        let signatures: [[UInt8]] = [[0xff, 0xd8, 0xff], [0x89, 0x50, 0x4e, 0x47], [0x47, 0x49, 0x46, 0x38], [0x49, 0x49, 0x2a, 0], [0x52, 0x49, 0x46, 0x46]]
        for signature in signatures where bytes.count >= signature.count {
            let key = bytes[0] ^ signature[0]
            if signature.indices.allSatisfy({ bytes[$0] ^ key == signature[$0] }) {
                return key == 0 ? data : Data(bytes.map { $0 ^ key })
            }
        }
        return data // ImageIO validates ordinary formats, including HEIC.
    }
}
