import Foundation
import CommonCrypto

/// The API supplies the AES key for authorized encraw media. Never derive or persist it.
nonisolated enum YandexEncrawDecryptor {
    enum Failure: Error { case invalidKey, invalidSize, crypto, emptyOutput }
    static let maximumFileBytes: Int64 = 128 * 1_024 * 1_024

    static func keyBytes(_ hex: String) throws -> Data {
        guard hex.utf8.count == 32, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalidKey
        }
        var result = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw Failure.invalidKey }
            result.append(byte); index = next
        }
        return result
    }

    /// AES-128-CTR, zero initial counter, big-endian increment: upstream decrypt_track contract.
    /// One cryptor lives across chunks, including partial blocks. Ciphertext never reaches a decoder.
    static func decryptFile(_ source: URL, to destination: URL, keyHex: String) throws {
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0, size <= maximumFileBytes else { throw Failure.invalidSize }
        var key = try keyBytes(keyHex)
        defer { key.resetBytes(in: 0..<key.count) }
        let iv = Data(repeating: 0, count: kCCBlockSizeAES128)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivBuffer.baseAddress, keyBuffer.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw Failure.crypto }
        defer { CCCryptorRelease(cryptor) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 65_537), !chunk.isEmpty {
            try Task.checkCancellation()
            total += Int64(chunk.count)
            guard total <= maximumFileBytes else { throw Failure.invalidSize }
            var plain = Data(count: chunk.count + kCCBlockSizeAES128); var written = 0
            let code = chunk.withUnsafeBytes { bytes in
                plain.withUnsafeMutableBytes { target in
                    CCCryptorUpdate(cryptor, bytes.baseAddress, chunk.count, target.baseAddress, target.count, &written)
                }
            }
            guard code == kCCSuccess else { throw Failure.crypto }
            plain.count = written; try output.write(contentsOf: plain)
        }
        var finalBytes = Data(count: kCCBlockSizeAES128); var written = 0
        let finalStatus = finalBytes.withUnsafeMutableBytes {
            CCCryptorFinal(cryptor, $0.baseAddress, $0.count, &written)
        }
        guard finalStatus == kCCSuccess, total == size else { throw Failure.crypto }
        finalBytes.count = written; try output.write(contentsOf: finalBytes)
        try output.synchronize(); try Task.checkCancellation()
        completed = true
    }
}
