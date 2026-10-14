import CommonCrypto
import CryptoKit
import Foundation

public enum MideaError: Error, Equatable, Sendable {
    /// The unit didn't answer in time.
    case timeout
    /// The TCP connection couldn't be opened or was dropped.
    case connection(String)
    /// The unit refused the token and key.
    case authentication(String)
    /// A packet or frame that doesn't follow the protocol.
    case malformed(String)
    case crypto
}

/// AES and hashes used by the Midea LAN protocol.
enum MideaCrypto {
    /// Fixed key shared by every Midea unit for the inner (V2) packet layer.
    static let signKey = Array("xhdiwjnchekd4d512chdjx5d8e4c394D2D7S".utf8)
    static let encryptionKey = md5(signKey)

    static func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: bytes)) }
    static func sha256(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }

    /// AES-CBC with a zero IV and no padding: the V3 layer pads by itself.
    static func cbc(encrypt: Bool, key: [UInt8], _ data: [UInt8]) throws -> [UInt8] {
        try crypt(encrypt: encrypt, options: 0, key: key, iv: [UInt8](repeating: 0, count: 16), data)
    }

    /// AES-128-ECB with PKCS#7 padding under the fixed key, for the V2 layer.
    static func ecb(encrypt: Bool, _ data: [UInt8]) throws -> [UInt8] {
        try crypt(
            encrypt: encrypt, options: CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
            key: encryptionKey, iv: nil, data
        )
    }

    private static func crypt(encrypt: Bool, options: CCOptions, key: [UInt8], iv: [UInt8]?, _ data: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
            key, key.count, iv, data, data.count, &output, capacity, &moved
        )
        guard status == kCCSuccess else { throw MideaError.crypto }
        return Array(output.prefix(moved))
    }
}
