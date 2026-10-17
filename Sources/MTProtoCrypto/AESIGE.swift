internal import CMTProtoAESIGE
import Crypto
import CryptoExtras

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// AES-256 in **IGE** (Infinite Garble Extension) mode, which MTProto uses for
/// both `server_DH_inner_data` and the encrypted message layer.
///
/// Each block chains with the previous ciphertext *and* plaintext block, seeding
/// `c_{-1}` / `p_{-1}` from the two halves of the 32-byte IV:
///
/// ```
/// c_i = E_K(p_i ⊕ c_{i-1}) ⊕ p_{i-1}
/// p_i = D_K(c_i ⊕ p_{i-1}) ⊕ c_{i-1}
/// ```
///
/// swift-crypto does not expose IGE, and its single-block permutation expands the
/// key on every call, so on CPUs with AES instructions the chain runs in the
/// `CMTProtoAESIGE` C target instead; see the module overview.
public enum AESIGE {
  static let blockSize = 16

  /// The implementation behind ``encrypt(_:key:iv:)`` and
  /// ``decrypt(_:key:iv:)``. Internal so tests can pin each one.
  enum Backend: Sendable, CaseIterable {
    /// The CPU's AES instructions; only valid when ``hardwareAvailable``.
    case hardware
    /// swift-crypto: one CBC call for encryption, one block permutation per
    /// block for decryption.
    case swiftCrypto
  }

  static let hardwareAvailable = cmtproto_aes_hw_available() != 0
  static let defaultBackend: Backend = hardwareAvailable ? .hardware : .swiftCrypto

  /// Encrypts `plaintext` (whose length must be a multiple of 16) with a
  /// 32-byte `key` and 32-byte `iv`.
  public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
    try transform(plaintext, key: key, iv: iv, encrypting: true, backend: defaultBackend)
  }

  /// Decrypts `ciphertext` (whose length must be a multiple of 16) with a
  /// 32-byte `key` and 32-byte `iv`.
  public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
    try transform(ciphertext, key: key, iv: iv, encrypting: false, backend: defaultBackend)
  }

  static func transform(
    _ input: Data, key: Data, iv: Data, encrypting: Bool, backend: Backend
  ) throws -> Data {
    guard key.count == 32 else {
      throw MTProtoCryptoError.invalidKeySize(expected: 32, actual: key.count)
    }
    guard iv.count == 32 else {
      throw MTProtoCryptoError.invalidIVSize(expected: 32, actual: iv.count)
    }
    guard input.count % blockSize == 0 else {
      throw MTProtoCryptoError.invalidBlockAlignment(length: input.count)
    }
    guard !input.isEmpty else { return Data() }

    switch backend {
    case .hardware:
      precondition(hardwareAvailable, "AES instructions are not available")
      var output = Data(count: input.count)
      key.withUnsafeBytes { key in
        iv.withUnsafeBytes { iv in
          input.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { output in
              let cipher = encrypting ? cmtproto_aes256_ige_encrypt : cmtproto_aes256_ige_decrypt
              cipher(
                key.baseAddress!.assumingMemoryBound(to: UInt8.self),
                iv.baseAddress!.assumingMemoryBound(to: UInt8.self),
                input.baseAddress!.assumingMemoryBound(to: UInt8.self),
                output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                input.count)
            }
          }
        }
      }
      return output
    case .swiftCrypto:
      return encrypting
        ? try swiftCryptoEncrypt(input, key: key, iv: iv)
        : try swiftCryptoDecrypt(input, key: key, iv: iv)
    }
  }

  /// IGE encryption is CBC encryption in disguise: with `y_i = c_i ⊕ p_{i-1}`,
  /// `y_i = E_K(x_i ⊕ y_{i-1})` for `x_i = p_i ⊕ p_{i-2}` (`p_{-2} = 0`,
  /// `y_{-1} = c_{-1}`). So one CBC call — one key expansion — does every block,
  /// with a linear pass on either side.
  private static func swiftCryptoEncrypt(_ plain: Data, key: Data, iv: Data) throws -> Data {
    let words = plain.count / 8
    var chained = Data(count: plain.count)
    plain.withUnsafeBytes { p in
      iv.withUnsafeBytes { iv in
        chained.withUnsafeMutableBytes { x in
          for j in 0..<words {
            var word = p.loadUnaligned(fromByteOffset: 8 * j, as: UInt64.self)
            if j >= 4 {
              word ^= p.loadUnaligned(fromByteOffset: 8 * (j - 4), as: UInt64.self)
            } else if j >= 2 {
              word ^= iv.loadUnaligned(fromByteOffset: 8 * j, as: UInt64.self)
            }
            x.storeBytes(of: word, toByteOffset: 8 * j, as: UInt64.self)
          }
        }
      }
    }
    var output = try AES._CBC.encrypt(
      chained, using: SymmetricKey(data: key), iv: AES._CBC.IV(ivBytes: iv.prefix(16)),
      noPadding: true)
    plain.withUnsafeBytes { p in
      iv.withUnsafeBytes { iv in
        output.withUnsafeMutableBytes { y in
          for j in 0..<words {
            let previous =
              j >= 2
              ? p.loadUnaligned(fromByteOffset: 8 * (j - 2), as: UInt64.self)
              : iv.loadUnaligned(fromByteOffset: 16 + 8 * j, as: UInt64.self)
            let word = y.loadUnaligned(fromByteOffset: 8 * j, as: UInt64.self) ^ previous
            y.storeBytes(of: word, toByteOffset: 8 * j, as: UInt64.self)
          }
        }
      }
    }
    return output
  }

  /// IGE decryption feeds each plaintext block into the next block's input, and
  /// swift-crypto has no sequential mode over the inverse cipher, so this stays
  /// one `AES.inversePermute` per block.
  private static func swiftCryptoDecrypt(_ cipher: Data, key: Data, iv: Data) throws -> Data {
    let symmetricKey = SymmetricKey(data: key)
    var block = [UInt8](repeating: 0, count: blockSize)
    var output = Data(count: cipher.count)
    try cipher.withUnsafeBytes { c in
      try output.withUnsafeMutableBytes { p in
        var (prevCipher0, prevCipher1, prevPlain0, prevPlain1) = iv.withUnsafeBytes { iv in
          (
            iv.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
            iv.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
            iv.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
            iv.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
          )
        }
        for offset in stride(from: 0, to: c.count, by: blockSize) {
          let cipher0 = c.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
          let cipher1 = c.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)
          block.withUnsafeMutableBytes { t in
            t.storeBytes(of: cipher0 ^ prevPlain0, toByteOffset: 0, as: UInt64.self)
            t.storeBytes(of: cipher1 ^ prevPlain1, toByteOffset: 8, as: UInt64.self)
          }
          try AES.inversePermute(&block, key: symmetricKey)
          let (plain0, plain1) = block.withUnsafeBytes { t in
            (
              t.loadUnaligned(fromByteOffset: 0, as: UInt64.self) ^ prevCipher0,
              t.loadUnaligned(fromByteOffset: 8, as: UInt64.self) ^ prevCipher1
            )
          }
          p.storeBytes(of: plain0, toByteOffset: offset, as: UInt64.self)
          p.storeBytes(of: plain1, toByteOffset: offset + 8, as: UInt64.self)
          (prevCipher0, prevCipher1, prevPlain0, prevPlain1) = (cipher0, cipher1, plain0, plain1)
        }
      }
    }
    return output
  }
}
